#!/bin/bash

error_exit() {
    echo -e "${RED}Ошибка: $1${NC}" >&2
    exit 1
}

if [ $# -eq 0 ]; then
    error_exit "Не указан путь к папке или ссылка на репозиторий"
fi

input="$1"
project_dir=""
if [[ "$input" =~ ^https?:// ]]; then
    project_dir=$(basename "$input" .git)
    git clone "$input" || error_exit "Не удалось клонировать репозиторий"
else
    [ -d "$input" ] || error_exit "Папка $input не существует"
    project_dir="$input"
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
EOF
}
create_base_pipeline

check_python_project() {
    local req_file=$(find "$project_dir" -type f -name "requirements.txt" -print -quit)
    local poetry_file=$(find "$project_dir" -type f -name "pyproject.toml" -print -quit)
    
    if [ -n "$req_file" ]; then
        cat >> "$pipeline_file" << EOF
      - name: install-dependencies
        command: pip install -r requirements.txt
      - name: run-tests
        command: pytest
EOF
        return 0
    elif [ -n "$poetry_file" ]; then
            cat >> "$pipeline_file" << EOF
      - name: install-dependencies
        command: poetry install
      - name: run-tests
        command: poetry run pytest
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

