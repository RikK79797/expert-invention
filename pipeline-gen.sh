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
      - name: install-dependencies
        run: pip install -r requirements.txt
      - name: run-tests
        run: pytest
EOF
        return 0
    elif [ -n "$poetry_file" ]; then
        cat >> "$pipeline_file" << EOF
      - name: install-dependencies
        run: poetry install
      - name: run-tests
        run: poetry run pytest
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
