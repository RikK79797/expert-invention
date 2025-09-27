#!/bin/bash

error_exit() {
    echo -e "${RED}Ошибка: $1${NC}" >&2
    exit 1
}

# Цвета для вывода (если не определены)
RED='\033[0;31m'
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
    git clone "$repo_url" || error_exit "Не удалось клонировать репозиторий"
    # Извлекаем owner/repo из URL (предполагаем GitHub)
    repo_path=$(echo "$repo_url" | sed -E 's|https?://github.com/||; s|\\.git$||')
elif [ -n "$project_dir" ]; then
    [ -d "$project_dir" ] || error_exit "Папка $project_dir не существует"
fi

pipeline_file="pipeline.yaml"
detected=false

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
    # Закрываем with: и добавляем базовый шаг (если нужно)
    cat >> "$pipeline_file" << EOF
      - name: Setup environment
        run: |
          echo "Project directory: \$(pwd)"
          ls -la
EOF
}
create_base_pipeline

check_python_project() {
    local req_file=$(find "$project_dir" -type f -name "requirements.txt" -print -quit)
    local poetry_file=$(find "$project_dir" -type f -name "pyproject.toml" -print -quit)

    if [ -n "$req_file" ]; then
        # Проверяем наличие main.py
        if [ -f "$project_dir/main.py" ] || find "$project_dir" -name "main.py" | grep -q .; then
            cat >> "$pipeline_file" << EOF
      - uses: actions/setup-python@v4
        with:
          python-version: '3.x'
      - name: Install Python dependencies
        run: pip install -r requirements.txt
      - name: Run Python application
        run: python main.py
EOF
            return 0
        fi
    elif [ -n "$poetry_file" ] && grep -q "\$tool.poetry\$" "$poetry_file"; then
        # Проверяем наличие main.py
        if [ -f "$project_dir/main.py" ] || find "$project_dir" -name "main.py" | grep -q .; then
            cat >> "$pipeline_file" << EOF
      - uses: actions/setup-python@v4
        with:
          python-version: '3.x'
      - name: Install Poetry
        run: pip install poetry
      - name: Install dependencies with Poetry
        run: poetry install --no-interaction
      - name: Run application with Poetry
        run: poetry run python main.py
EOF
            return 0
        fi
    fi
    return 1
}

check_javascript_project() {
    local package_json=$(find "$project_dir" -type f -name "package.json" -print -quit)
    
    if [ -z "$package_json" ]; then
        return 1
    fi

    # Проверяем наличие скрипта "start" в package.json
    if ! grep -q '"start"' "$package_json"; then
        echo "Предупреждение: Нет скрипта 'start' в package.json"
        return 1
    fi

    local manager="npm"
    local has_npm_lock=false
    if [ -f "$project_dir/pnpm-lock.yaml" ]; then
        manager="pnpm"
    elif [ -f "$project_dir/yarn.lock" ]; then
        manager="yarn"
    elif [ -f "$project_dir/package-lock.json" ]; then
        manager="npm"
        has_npm_lock=true
    else
        manager="npm"
        has_npm_lock=false
    fi

    case "$manager" in
        "npm")
            if [ "$has_npm_lock" = true ]; then
                install_cmd="npm ci"
            else
                install_cmd="npm install"
            fi
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
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: '$manager'
      - name: Install Node.js dependencies ($manager)
        run: $install_cmd
      - name: Run JavaScript application
        run: $start_cmd
EOF

    return 0
}

check_go_project() {
    local go_mod=$(find "$project_dir" -type f -name "go.mod" -print -quit)
    
    if [ -n "$go_mod" ]; then
        # Проверяем наличие main.go
        if find "$project_dir" -name "*.go" | grep -q "main"; then
            cat >> "$pipeline_file" << EOF
      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'
      - name: Download Go modules
        run: go mod download
      - name: Run Go application
        run: go run .
EOF
            return 0
        fi
    fi
    return 1
}

check_rust_project() {
    local cargo_toml=$(find "$project_dir" -type f -name "Cargo.toml" -print -quit)
    
    if [ -n "$cargo_toml" ]; then
        # Проверяем наличие src/main.rs
        if [ -f "$project_dir/src/main.rs" ]; then
            cat >> "$pipeline_file" << EOF
      - uses: actions-rs/toolchain@v1
        with:
          toolchain: stable
      - name: Fetch Rust dependencies
        run: cargo fetch
      - name: Run Rust application
        run: cargo run
EOF
            return 0
        fi
    fi
    return 1
}

check_ruby_project() {
    local gemfile=$(find "$project_dir" -type f -name "Gemfile" -print -quit)
    local gemfile_lock=$(find "$project_dir" -type f -name "Gemfile.lock" -print -quit)
    local app_rb=$(find "$project_dir" -type f -name "app.rb" -print -quit)
    local config_ru=$(find "$project_dir" -type f -name "config.ru" -print -quit)
    local rakefile=$(find "$project_dir" -type f -name "Rakefile" -print -quit)

    if [ -n "$gemfile" ] && [ -n "$gemfile_lock" ] && { [ -n "$app_rb" ] || [ -n "$config_ru" ] || [ -n "$rakefile" ]; }; then
        cat >> "$pipeline_file" << EOF
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.1'
          bundler-cache: true
      - name: Install Ruby dependencies
        run: bundle install
      - name: Run Ruby application
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
    fi
    return 1
}

# Цикл обнаружения
CHECK_FUNCTIONS=$(declare -F | awk '{print $3}' | grep '^check_')
for func in $CHECK_FUNCTIONS; do
    "$func"
    if [ $? -eq 0 ]; then
        detected=true
        break
    fi
done

# Fallback, если ни один тип не обнаружен
if [ "$detected" = false ]; then
    echo "Предупреждение: Тип проекта не распознан. Добавляем fallback-шаги."
    cat >> "$pipeline_file" << EOF
      - uses: actions/setup-python@v4
        with:
          python-version: '3.x'
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'
      - name: Fallback - No project type detected
        run: |
          echo "Project files:"
          ls -la
          echo "No specific build steps added. Customize pipeline.yaml manually."
EOF
fi

# Закрытие пайплайна (YAML закроется автоматически, но добавим комментарий для ясности)
cat >> "$pipeline_file" << EOF

EOF

echo "Пайплайн сгенерирован: $pipeline_file"
echo "Если проект не распознан, отредактируйте файл вручную для кастомных шагов."



# #!/bin/bash

# error_exit() {
#     echo -e "${RED}Ошибка: $1${NC}" >&2
#     exit 1
# }

# repo_url=""
# project_dir=""
# branch_name="main"
# while [[ $# -gt 0 ]]; do
#     case "$1" in
#         --repo)
#             repo_url="$2"
#             shift 2
#             ;;
#         --dir)
#             project_dir="$2"
#             shift 2
#             ;;
#         --branch)
#             if [ -n "$2" ]; then
#                 branch_name="$2"
#             fi
#             shift 2
#             ;;
#         *)
#             error_exit "Неизвестный аргумент: $1. Используйте --repo или --dir"
#             ;;
#     esac
# done
# if [ -z "$repo_url" ] && [ -z "$project_dir" ]; then
#     error_exit "Не указан ни репозиторий (--repo), ни папка (--dir)"
# fi

# if [[ "$repo_url" =~ ^https?:// ]]; then
#     project_dir=$(basename "$repo_url" .git)
#     git clone "$repo_url" || error_exit "Не удалось клонировать репозиторий"
#     # Извлекаем owner/repo из URL
#     repo_path=$(echo "$repo_url" | sed -E 's|https?://github.com/||; s|\\.git$||')
# elif [ -n "$project_dir" ]; then
#     [ -d "$project_dir" ] || error_exit "Папка $project_dir не существует"
# fi

# pipeline_file="pipeline.yaml"
# create_base_pipeline() {
#     cat > "$pipeline_file" << EOF
# name: CI Pipeline
# on:
#   workflow_dispatch:
# jobs:
#   build:
#     runs-on: ubuntu-latest
#     steps:
#       - uses: actions/checkout@v3
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

# check_python_project() {
#     local req_file=$(find "$project_dir" -type f -name "requirements.txt" -print -quit)
#     local poetry_file=$(find "$project_dir" -type f -name "pyproject.toml" -print -quit)

#     if [ -n "$req_file" ]; then
#         cat >> "$pipeline_file" << EOF
#       - name: Install Python dependencies
#         run: pip install -r requirements.txt
#       - name: Run Python application
#         run: python main.py
# EOF
#         return 0
#     elif [ -n "$poetry_file" ]; then
#         cat >> "$pipeline_file" << EOF
#       - name: Install Poetry
#         run: pip install poetry
#       - name: Install dependencies with Poetry
#         run: poetry install --no-interaction
#       - name: Run application with Poetry
#         run: poetry run python main.py
# EOF
#         return 0
#     else
#         return 1
#     fi
# }

# check_javascript_project() {
#     local package_json=$(find "$project_dir" -type f -name "package.json" -print -quit)
    
#     if [ -z "$package_json" ]; then
#         return 1
#     fi

#     local manager="npm"
#     if [ -f "$project_dir/pnpm-lock.yaml" ]; then
#         manager="pnpm"
#     elif [ -f "$project_dir/yarn.lock" ]; then
#         manager="yarn"
#     elif [ -f "$project_dir/package-lock.json" ]; then
#         manager="npm"
#     else
#         manager="npm"  # fallback
#     fi

#     case "$manager" in
#         "npm")
#             install_cmd="npm ci"
#             start_cmd="npm start"
#             ;;
#         "yarn")
#             install_cmd="yarn install --frozen-lockfile"
#             start_cmd="yarn start"
#             ;;
#         "pnpm")
#             install_cmd="pnpm install --frozen-lockfile"
#             start_cmd="pnpm start"
#             ;;
#     esac

#     cat >> "$pipeline_file" << EOF
#       - name: Install Node.js dependencies ($manager)
#         run: $install_cmd
#       - name: Run JavaScript application
#         run: $start_cmd
# EOF
#     return 0
# }

# check_go_project() {
#     local go_mod=$(find "$project_dir" -type f -name "go.mod" -print -quit)
    
#     if [ -n "$go_mod" ]; then
#         cat >> "$pipeline_file" << EOF
#       - name: Download Go modules
#         run: go mod download
#       - name: Run Go application
#         run: go run .
# EOF
#         return 0
#     else
#         return 1
#     fi
# }

# check_rust_project() {
#     local cargo_toml=$(find "$project_dir" -type f -name "Cargo.toml" -print -quit)
    
#     if [ -n "$cargo_toml" ]; then
#         cat >> "$pipeline_file" << EOF
#       - name: Fetch Rust dependencies
#         run: cargo fetch
#       - name: Run Rust application
#         run: cargo run
# EOF
#         return 0
#     else
#         return 1
#     fi
# }

# check_ruby_project() {
#     local gemfile=$(find "$project_dir" -type f -name "Gemfile" -print -quit)
#     local gemfile_lock=$(find "$project_dir" -type f -name "Gemfile.lock" -print -quit)
#     local app_rb=$(find "$project_dir" -type f -name "app.rb" -print -quit)
#     local config_ru=$(find "$project_dir" -type f -name "config.ru" -print -quit)
#     local rakefile=$(find "$project_dir" -type f -name "Rakefile" -print -quit)

#     if [ -n "$gemfile" ] && [ -n "$gemfile_lock" ] && { [ -n "$app_rb" ] || [ -n "$config_ru" ] || [ -n "$rakefile" ]; }; then
#         cat >> "$pipeline_file" << EOF
#       - name: Install Ruby dependencies
#         run: bundle install
#       - name: Run Ruby application
#         run: |
#           if [ -f "app.rb" ]; then
#             bundle exec ruby app.rb
#           elif [ -f "config.ru" ]; then
#             bundle exec rackup config.ru
#           elif [ -f "Rakefile" ]; then
#             bundle exec rake
#           else
#             echo "No known entry point found."
#             exit 1
#           fi
# EOF
#         return 0
#     else
#         return 1
#     fi
# }

# CHECK_FUNCTIONS=$(declare -F | awk '{print $3}' | grep '^check_')
# success=0
# for func in $CHECK_FUNCTIONS; do
#     if "$func"; then
#         success=1
#         break
#     fi
# done
# if [ $success -eq 0 ]; then
#     echo -e "😅 Бывает... возможно язык не поддерживается этим скриптом или возникла непредвиденная ошибка."
# fi
