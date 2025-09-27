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

if [[ "$repo_url" =~ ^https?:// ]]; then
    project_dir=$(basename "$repo_url" .git)
    git clone "$repo_url" || error_exit "Не удалось клонировать репозиторий"
    # Извлекаем owner/repo из URL
    repo_path=$(echo "$repo_url" | sed -E 's|https?://github.com/||; s|\\.git$||')
elif [ -n "$project_dir" ]; then
    [ -d "$project_dir" ] || error_exit "Папка $project_dir не существует"
fi

pipeline_file="pipeline.yaml"
create_base_pipeline() {
    cat > "$pipeline_file" << EOF
name: CI Pipeline
on:
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
        with:
EOF
    if [ -n "$repo_path" ] && [ -n "$branch_name" ]; then
        cat >> "$pipeline_file" << EOF
          repository: $repo_path
          ref: $branch_name
EOF
    fi
}
create_base_pipeline

check_python_project() {
    local req_file=$(find "$project_dir" -type f -name "requirements.txt" -print -quit)
    local poetry_file=$(find "$project_dir" -type f -name "pyproject.toml" -print -quit)

    if [ -n "$req_file" ]; then
        cat >> "$pipeline_file" << EOF
  - name: Install Python dependencies
    working-directory: $project_dir
    run: pip install -r requirements.txt

  - name: Run Python application
    working-directory: $project_dir
    run: python main.py
EOF
        return 0
    elif [ -n "$poetry_file" ]; then
        cat >> "$pipeline_file" << EOF
  - name: Install Poetry
    run: pip install poetry

  - name: Install dependencies with Poetry
    working-directory: $project_dir
    run: poetry install --no-interaction

  - name: Run application with Poetry
    working-directory: $project_dir
    run: poetry run python main.py
EOF
        return 0
    else
        return 1
    fi
}

check_javascript_project() {
    local package_json=$(find "$project_dir" -type f -name "package.json" -print -quit)
    
    if [ -z "$package_json" ]; then
        return 1
    fi

    local manager="npm"
    if [ -f "$project_dir/pnpm-lock.yaml" ]; then
        manager="pnpm"
    elif [ -f "$project_dir/yarn.lock" ]; then
        manager="yarn"
    elif [ -f "$project_dir/package-lock.json" ]; then
        manager="npm"
    else
        manager="npm"  # fallback
    fi

    case "$manager" in
        "npm")
            install_cmd="npm ci"
            start_cmd="npm start"
            ;;
        "yarn")
            install_cmd="yarn install --frozen-lockfile"
            start_cmd="yarn start"
            ;;
        "pnpm")
            install_cmd="pnpm install --frozen-lockfile"
            start_cmd="pnpm start"
            ;;
    esac

    cat >> "$pipeline_file" << EOF
  - name: Install Node.js dependencies ($manager)
    working-directory: $project_dir
    run: $install_cmd

  - name: Run JavaScript application
    working-directory: $project_dir
    run: $start_cmd
EOF
    return 0
}

check_go_project() {
    local go_mod=$(find "$project_dir" -type f -name "go.mod" -print -quit)
    
    if [ -n "$go_mod" ]; then
        cat >> "$pipeline_file" << EOF
  - name: Download Go modules
    working-directory: $project_dir
    run: go mod download

  - name: Run Go application
    working-directory: $project_dir
    run: go run .
EOF
        return 0
    else
        return 1
    fi
}

check_rust_project() {
    local cargo_toml=$(find "$project_dir" -type f -name "Cargo.toml" -print -quit)
    
    if [ -n "$cargo_toml" ]; then
        cat >> "$pipeline_file" << EOF
  - name: Fetch Rust dependencies
    working-directory: $project_dir
    run: cargo fetch

  - name: Run Rust application
    working-directory: $project_dir
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
    local app_rb=$(find "$project_dir" -type f -name "app.rb" -print -quit)
    local config_ru=$(find "$project_dir" -type f -name "config.ru" -print -quit)
    local rakefile=$(find "$project_dir" -type f -name "Rakefile" -print -quit)

    if [ -n "$gemfile" ] && [ -n "$gemfile_lock" ] && { [ -n "$app_rb" ] || [ -n "$config_ru" ] || [ -n "$rakefile" ]; }; then
        cat >> "$pipeline_file" << EOF
  - name: Install Ruby dependencies
    working-directory: $project_dir
    run: bundle install

  - name: Run Ruby application
    working-directory: $project_dir
    run: |
      if [ -f "app.rb" ]; then
        bundle exec ruby app.rb
      elif [ -f "config.ru" ]; then
        bundle exec rackup config.ru
      elif [ -f "Rakefile" ]; then
        bundle exec rake
      else
        echo "No known entry point found."
        exit 1
      fi
EOF
        return 0
    else
        return 1
    fi
}

CHECK_FUNCTIONS=$(declare -F | awk '{print $3}' | grep '^check_')
success=0
for func in $CHECK_FUNCTIONS; do
    if "$func"; then
        success=1
        break
    fi
done
if [ $success -eq 0 ]; then
    echo "⚠️  Автоматически определить проект не удалось."
    if command -v enry >/dev/null 2>&1; then
        echo "👉 Запускаем enry для анализа..."
        (cd "$project_dir" && enry || echo "Enry не смог проанализировать репозиторий")
    else
        echo "😅 Enry не установлен. Установите его: go install github.com/go-enry/enry@latest"
    fi
fi
