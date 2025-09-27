#!/bin/bash

error_exit() {
    echo -e "${RED}Ошибка: $1${NC}" >&2
    exit 1
}

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
            branch_name="$2"
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

if [[ "$repo_url" =~ ^https?:// ]]; then
    project_dir=$(basename "$repo_url" .git)
    git clone "$repo_url" || error_exit "Не удалось клонировать репозиторий"
    # Извлекаем owner/repo из URL
    repo_path=$(echo "$repo_url" | sed -E 's|https?://github.com/||; s|\\.git$||')
elif [ -n "$project_dir" ]; then
    [ -d "$project_dir" ] || error_exit "Папка $project_dir не существует"
fi

# pipeline_file="pipeline.yaml"
mkdir -p .github/workflows
pipeline_file=".github/workflows/pipeline.yml"

# create_base_pipeline() {
#     cat > "$pipeline_file" << EOF
# name: CI Pipeline
# on:
#   workflow_dispatch:
# jobs:
#   build:
#     runs-on: ubuntu-latest
#     steps:
#      - name: Checkout code
#        uses: actions/checkout@v3
#         with:
# EOF
#     if [ -n "$repo_path" ] && [ -n "$branch_name" ]; then
#         cat >> "$pipeline_file" << EOF
#           repository: $repo_path
#           ref: $branch_name
# EOF
#     fi
# }
# create_base_pipeline
create_base_pipeline() {
    cat > "$pipeline_file" << 'EOF'
name: CI Pipeline
on:
  push:
    branches: [ main, master ]
  pull_request:
    branches: [ main, master ]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
EOF
    
    if [ -n "$repo_url" ] && [ -n "$branch_name" ]; then
        cat >> "$pipeline_file" << EOF
        with:
          repository: $(echo "$repo_url" | sed -E 's|https?://github.com/||; s|\.git$||')
          ref: $branch_name
EOF
    fi
}

check_python_project() {
    local req_file=$(find "$project_dir" -type f -name "requirements.txt" -print -quit)
    local poetry_file=$(find "$project_dir" -type f -name "pyproject.toml" -print -quit)
    
    if [ -n "$req_file" ]; then
        cat >> "$pipeline_file" << EOF
      - name: install-dependencies
        run: pip install -r requirements.txt
      - name: run-application
        run: python -m pytest || python app.py
EOF
        return 0
    elif [ -n "$poetry_file" ]; then
        cat >> "$pipeline_file" << EOF
      - name: install-dependencies
        run: poetry install
      - name: run-application
        run: poetry run pytest || poetry run python app.py
EOF
        return 0
    else
        return 1
    fi
}

check_javascript_project() {
    local package_json=$(find "$project_dir" -type f -name "package.json" -print -quit)
    local lock_file=""
    
    if [ -n "$package_json" ]; then
        if [ -f "$project_dir/package-lock.json" ]; then
            lock_file="package-lock.json"
        elif [ -f "$project_dir/yarn.lock" ]; then
            lock_file="yarn.lock"
        elif [ -f "$project_dir/pnpm-lock.yaml" ]; then
            lock_file="pnpm-lock.yaml"
        fi

        cat >> "$pipeline_file" << EOF
      - name: install-dependencies
        run: npm ci
      - name: run-application
        run: npm start
EOF
        return 0
    else
        return 1
    fi
}

check_go_project() {
    local go_mod=$(find "$project_dir" -type f -name "go.mod" -print -quit)
    local go_sum=$(find "$project_dir" -type f -name "go.sum" -print -quit)
    
    if [ -n "$go_mod" ] && [ -n "$go_sum" ]; then
        cat >> "$pipeline_file" << EOF
      - name: install-dependencies
        run: go mod download
      - name: run-application
        run: go run .
EOF
        return 0
    else
        return 1
    fi
}

check_rust_project() {
    local cargo_toml=$(find "$project_dir" -type f -name "Cargo.toml" -print -quit)
    local cargo_lock=$(find "$project_dir" -type f -name "Cargo.lock" -print -quit)
    
    if [ -n "$cargo_toml" ] && [ -n "$cargo_lock" ]; then
        cat >> "$pipeline_file" << EOF
      - name: install-dependencies
        run: cargo fetch
      - name: run-application
        run: cargo run
EOF
        return 0
    else
        return 1
    fi
}

check_ruby_project() {
    local gemfile=$(find "$project_dir" -type f -name "Gemfile" -print -quit)
    local gemfile_lock=$(find "$project_dir" -type f -name "Gemfile.lock" -print -quit)
    local config_ru=$(find "$project_dir" -type f -name "config.ru" -print -quit)
    local rakefile=$(find "$project_dir" -type f -name "Rakefile" -print -quit)
    
    if [ -n "$gemfile" ] && [ -n "$gemfile_lock" ] && { [ -n "$config_ru" ] || [ -n "$rakefile" ]; }; then
        cat >> "$pipeline_file" << EOF
      - name: install-dependencies
        run: bundle install
      - name: run-application
        run: bundle exec ruby app.rb || bundle exec rackup
EOF
        return 0
    else
        return 1
    fi
}

CHECK_FUNCTIONS=$(declare -F | awk '{print $3}' | grep '^check_')
for func in $CHECK_FUNCTIONS; do
    "$func"
    if [ $? -eq 0 ]; then
        break
    fi
done
