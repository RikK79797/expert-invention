#!/bin/bash

error_exit() {
    echo -e "${RED}Ошибка: $1${NC}" >&2
    exit 1
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

repo_url=""
project_dir=""
branch_name="main"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            repo_url="$2"
            shift 2
            ;;
        --dir)
            project_dir="$2"
            shift 2
            ;;
        --branch)
            if [ -n "$2" ]; then
                branch_name="$2"
            fi
            shift 2
            ;;
        *)
            error_exit "Неизвестный аргумент: $1. Используйте --repo или --dir"
            ;;
    esac
done

if [ -z "$repo_url" ] && [ -z "$project_dir" ]; then
    error_exit "Не указан ни репозиторий (--repo), ни папка (--dir)"
fi

repo_path=""
if [[ "$repo_url" =~ ^https?:// ]]; then
    project_dir=$(basename "$repo_url" .git)
    rm -rf "$project_dir" 
    git clone --branch "$branch_name" "$repo_url" "$project_dir" || error_exit "Не удалось клонировать репозиторий"
    repo_path=$(echo "$repo_url" | sed -E 's|https?://github.com/||; s|\\.git$||')
elif [ -n "$project_dir" ]; then
    [ -d "$project_dir" ] || error_exit "Папка $project_dir не существует"
fi

project_dir="$(cd "$project_dir" && pwd)"

pipeline_file="pipeline.yaml"
detected=false
project_type="unknown"

create_base_pipeline() {
    cat > "$pipeline_file" << EOF
name: CI Pipeline
on:
  push:
    branches: [ "$branch_name" ]
  pull_request:
    branches: [ "$branch_name" ]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
EOF

    if [ -n "$repo_path" ]; then
        cat >> "$pipeline_file" << EOF
        with:
          repository: $repo_path
          ref: $branch_name
EOF
    fi

    cat >> "$pipeline_file" << EOF
      - name: Detect project type and list files
        run: |
          echo "Project directory: \$(pwd)"
          echo "Detected files:"
          find . -type f -name "*.json" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.rb" | head -20
          echo "Root directory contents:"
          ls -la
EOF
}

create_base_pipeline

# === Python ===
check_python_project() {
    local req_file=$(find "$project_dir" -maxdepth 2 -type f -name "requirements.txt" -print -quit)
    local poetry_file=$(find "$project_dir" -maxdepth 2 -type f -name "pyproject.toml" -print -quit)
    local setup_file=$(find "$project_dir" -maxdepth 2 -type f -name "setup.py" -print -quit)

    if [ -n "$poetry_file" ] && grep -q "\[tool\.poetry\]" "$poetry_file" 2>/dev/null; then
        project_type="python-poetry"
        local python_version=$(grep "python" "$poetry_file" | grep -E "'(3\.[0-9]+)'" | head -1 | sed "s/.*'\([^']*\)'.*/\1/" || echo "3.x")
        
        cat >> "$pipeline_file" << EOF
      - name: Setup Python
        uses: actions/setup-python@v4
        with:
          python-version: '$python_version'
          cache: 'poetry'
      
      - name: Install Poetry
        run: pip install poetry
      
      - name: Install dependencies
        run: poetry install --no-interaction --no-root
      
      - name: Run tests
        run: |
          if poetry run pytest --version >/dev/null 2>&1; then
            poetry run pytest
          else
            echo "No pytest configured, running basic checks"
            poetry check
          fi
EOF

        # Check if it's an application
        if find "$project_dir" -name "*.py" -exec grep -l "if __name__.*__main__" {} \; | head -1 | grep -q .; then
            cat >> "$pipeline_file" << EOF
      
      - name: Build and run application
        run: poetry install && poetry run python -c "import sys; print('Python application ready')"
EOF
        fi
        return 0
        
    elif [ -n "$req_file" ] || [ -n "$setup_file" ]; then
        project_type="python-pip"
        
        cat >> "$pipeline_file" << EOF
      - name: Setup Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.x'
          cache: 'pip'
      
      - name: Install dependencies
        run: |
          if [ -f requirements.txt ]; then
            pip install -r requirements.txt
          elif [ -f setup.py ]; then
            pip install -e .
          fi
      
      - name: Run tests
        run: |
          if python -m pytest --version >/dev/null 2>&1; then
            python -m pytest
          elif [ -f setup.py ]; then
            python setup.py test
          else
            echo "No test framework detected"
            python -c "import sys; print('Python environment ready')"
          fi
EOF
        return 0
    fi
    return 1
}

# === JavaScript/TypeScript ===
check_javascript_project() {
    local package_json=$(find "$project_dir" -maxdepth 2 -type f -name "package.json" -print -quit)
    [ -z "$package_json" ] && return 1

    project_type="javascript"
    local manager="npm"
    local install_cmd="npm ci"
    local build_cmd="npm run build --if-present"
    local test_cmd="npm test --if-present"
    local start_cmd="npm start --if-present"

    if [ -f "$project_dir/pnpm-lock.yaml" ]; then
        manager="pnpm"
        install_cmd="pnpm install --frozen-lockfile"
        build_cmd="pnpm run build --if-present"
        test_cmd="pnpm run test --if-present"
        start_cmd="pnpm run start --if-present"
    elif [ -f "$project_dir/yarn.lock" ]; then
        manager="yarn"
        install_cmd="yarn install --frozen-lockfile"
        build_cmd="yarn build --if-present"
        test_cmd="yarn test --if-present"
        start_cmd="yarn start --if-present"
    elif [ -f "$project_dir/package-lock.json" ]; then
        manager="npm"
        install_cmd="npm ci"
    fi

    # Detect TypeScript
    local has_tsconfig=$(find "$project_dir" -maxdepth 2 -type f -name "tsconfig.json" -print -quit)
    local node_version="18"
    
    cat >> "$pipeline_file" << EOF
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '$node_version'
          cache: '$manager'
      
      - name: Install dependencies
        run: $install_cmd
EOF

    if [ -n "$has_tsconfig" ]; then
        cat >> "$pipeline_file" << EOF
      
      - name: TypeScript compilation
        run: |
          if [ -f node_modules/.bin/tsc ]; then
            npx tsc --noEmit
          else
            echo "TypeScript compiler not found, skipping type check"
          fi
EOF
    fi

    cat >> "$pipeline_file" << EOF
      
      - name: Run tests
        run: $test_cmd
      
      - name: Build project
        run: $build_cmd
      
      - name: Security audit
        run: |
          if [ "$manager" = "npm" ]; then
            npm audit --audit-level moderate || true
          elif [ "$manager" = "yarn" ]; then
            yarn audit --level moderate || true
          fi
EOF

    # Check if it's a startable application
    if grep -q '"start"' "$package_json"; then
        cat >> "$pipeline_file" << EOF
      
      - name: Verify application start
        run: |
          timeout 10s $start_cmd || echo "Application start check completed"
EOF
    fi
    
    return 0
}

# === Go ===
check_go_project() {
    local go_mod=$(find "$project_dir" -maxdepth 2 -type f -name "go.mod" -print -quit)
    [ -z "$go_mod" ] && return 1

    project_type="go"
    local go_version=$(grep "^go " "$go_mod" | cut -d' ' -f2 || echo "1.21")
    
    cat >> "$pipeline_file" << EOF
      - name: Setup Go
        uses: actions/setup-go@v4
        with:
          go-version: '$go_version'
          cache: true
      
      - name: Download dependencies
        run: go mod download
      
      - name: Run tests
        run: go test ./...
      
      - name: Build verification
        run: go build -v ./...
      
      - name: Vet and lint
        run: |
          go vet ./...
          if command -v golangci-lint >/dev/null 2>&1; then
            golangci-lint run
          else
            echo "golangci-lint not installed, skipping"
          fi
EOF

    # Check for main application
    if find "$project_dir" -name "*.go" -exec grep -l "func main" {} \; | grep -q .; then
        cat >> "$pipeline_file" << EOF
      
      - name: Build executable
        run: go build -o main .
EOF
    fi
    
    return 0
}

# === Rust ===
check_rust_project() {
    local cargo_toml=$(find "$project_dir" -maxdepth 2 -type f -name "Cargo.toml" -print -quit)
    [ -z "$cargo_toml" ] && return 1

    project_type="rust"
    
    cat >> "$pipeline_file" << EOF
      - name: Setup Rust
        uses: dtolnay/rust-toolchain@stable
      
      - name: Cache cargo registry
        uses: actions/cache@v3
        with:
          path: |
            ~/.cargo/registry
            ~/.cargo/git
            target
          key: \${{ runner.os }}-cargo-\${{ hashFiles('**/Cargo.lock') }}
      
      - name: Build project
        run: cargo build --verbose
      
      - name: Run tests
        run: cargo test --verbose
      
      - name: Check code quality
        run: |
          cargo check
          cargo clippy -- -D warnings
EOF

    if [ -f "$project_dir/src/main.rs" ] || grep -q '\[\[bin\]\]' "$cargo_toml" || grep -q '\[bin\]' "$cargo_toml"; then
        cat >> "$pipeline_file" << EOF
      
      - name: Build release binary
        run: cargo build --release
EOF
    fi
    
    return 0
}

# === Ruby ===
check_ruby_project() {
    local gemfile=$(find "$project_dir" -maxdepth 2 -type f -name "Gemfile" -print -quit)
    [ -z "$gemfile" ] && return 1

    project_type="ruby"
    local ruby_version="3.1"
    
    if [ -f "$project_dir/.ruby-version" ]; then
        ruby_version=$(cat "$project_dir/.ruby-version" | tr -d '\n')
    fi

    cat >> "$pipeline_file" << EOF
      - name: Setup Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: '$ruby_version'
          bundler-cache: true
      
      - name: Install dependencies
        run: bundle install
      
      - name: Run tests
        run: |
          if bundle exec rake -T | grep -q test; then
            bundle exec rake test
          elsif [ -f Rakefile ] && grep -q "spec" Rakefile; then
            bundle exec rake spec
          else
            echo "No test task found"
          fi
EOF

    # Rails detection
    if grep -q "rails" "$gemfile"; then
        cat >> "$pipeline_file" << EOF
      
      - name: Rails specific tasks
        run: |
          if [ -f Rakefile ]; then
            bundle exec rake db:create db:migrate RAILS_ENV=test
            bundle exec rake assets:precompile
          fi
EOF
    fi
    
    return 0
}

# Execute detection functions in order
CHECK_FUNCTIONS="check_python_project check_javascript_project check_go_project check_rust_project check_ruby_project"

for func in $CHECK_FUNCTIONS; do
    if type "$func" >/dev/null 2>&1; then
        "$func"
        if [ $? -eq 0 ]; then
            detected=true
            echo -e "${GREEN}Обнаружен проект типа: $project_type${NC}"
            break
        fi
    fi
done

if [ "$detected" = false ]; then
    echo -e "${YELLOW}Предупреждение: Тип проекта не распознан${NC}"
    cat >> "$pipeline_file" << EOF
      - name: Multi-language setup
        run: |
          echo "Setting up multiple language environments for unknown project type"
          
      - name: Basic project analysis
        run: |
          echo "=== Project Structure ==="
          find . -type f -name "*.json" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.rb" | head -10
          echo "=== Build Files ==="
          find . -maxdepth 2 -type f -name "package.json" -o -name "requirements.txt" -o -name "go.mod" -o -name "Cargo.toml" -o -name "Gemfile" | head -10
          
      - name: Manual setup required
        run: |
          echo "No specific project type detected. Please customize this pipeline manually."
          echo "Common next steps:"
          echo "1. Add language-specific setup steps"
          echo "2. Configure build commands"
          echo "3. Add testing frameworks"
          echo "4. Set up deployment if needed"
EOF
fi

# Add final summary step
cat >> "$pipeline_file" << EOF

      - name: Pipeline completion
        run: |
          echo "✅ CI Pipeline completed successfully"
          echo "Project type: $project_type"
          echo "Branch: $branch_name"
          date

EOF

echo -e "${GREEN}Пайплайн сгенерирован: $pipeline_file${NC}"
echo -e "${GREEN}Тип проекта: ${project_type}${NC}"
echo -e "${YELLOW}Проверьте сгенерированный пайплайн и при необходимости доработайте его вручную.${NC}"
