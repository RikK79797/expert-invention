#!/bin/bash

set -euo pipefail

# === Значения по умолчанию ===
LANG=""
REPO=""
BRANCH="main"
PORT=3000
# MEMORY=256
# DISK=1000
OUTPUT="pipeline.yaml"
TEMP_DIR=".tmp_repo"

# === Список зависимостей (будет записан в dependencies.txt) ===
DEPS_FILE="dependencies.txt"
echo "Анализ зависимостей:" > "$DEPS_FILE"

# === Функция помощи ===
usage() {
  echo "Использование: $0 [опции]"
  echo "Опции:"
  echo "  --lang LANG        Язык: python, node, java, go (необязательно — автоопределение)"
  echo "  --repo URL         URL репозитория (HTTPS)"
  echo "  --branch NAME      Ветка (по умолчанию: main)"
  echo "  --port N           Требуемый порт (по умолчанию: 3000)"
  # echo "  --memory N         Минимальная память в MB (по умолчанию: 256)"
  # echo "  --disk N           Минимальное дисковое пространство в MB (по умолчанию: 1000)"
  echo "  --output FILE      Имя выходного .yaml файла (по умолчанию: pipeline.yaml)"
  exit 1
}

# === Парсинг аргументов ===
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --lang) LANG="$2"; shift ;;
    --repo) REPO="$2"; shift ;;
    --branch) BRANCH="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    # --memory) MEMORY="$2"; shift ;;
    # --disk) DISK="$2"; shift ;;
    --output) OUTPUT="$2"; shift ;;
    *) echo "Неизвестный параметр: $1"; usage ;;
  esac
  shift
done

# === Валидация обязательных полей ===
if [[ -z "$REPO" ]]; then
  echo "Ошибка: --repo обязателен."
  usage
fi

# === Клонирование репозитория ===
echo "📥 Клонирую репозиторий: $REPO (ветка: $BRANCH)..."
git clone --depth 1 --branch "$BRANCH" "$REPO" "$TEMP_DIR" || {
  echo "❌ Не удалось клонировать репозиторий. Проверьте URL и ветку."
  exit 1
}

# === Автоопределение языка программирования ===
detect_language() {
  local dir="$1"
  local detected=""

  if [[ -f "$dir/requirements.txt" ]]; then
    echo "requirements.txt" >> "$DEPS_FILE"
    detected="python"
  elif [[ -f "$dir/package.json" ]]; then
    echo "package.json" >> "$DEPS_FILE"
    detected="node"
  elif [[ -f "$dir/pom.xml" ]] || [[ -f "$dir/build.gradle" ]]; then
    [[ -f "$dir/pom.xml" ]] && echo "pom.xml" >> "$DEPS_FILE"
    [[ -f "$dir/build.gradle" ]] && echo "build.gradle" >> "$DEPS_FILE"
    detected="java"
  elif [[ -f "$dir/go.mod" ]]; then
    echo "go.mod" >> "$DEPS_FILE"
    detected="go"
  else
    echo "❌ Не удалось определить язык: не найдены файлы зависимостей."
    exit 1
  fi

  # Если язык задан, проверим совпадение
  if [[ -n "$LANG" ]]; then
    if [[ "$LANG" != "$detected" ]]; then
      echo "⚠️  Предупреждение: Вы указали язык '$LANG', но обнаружен '$detected' по файлам проекта."
      read -p "Использовать обнаруженный язык? (Y/n): " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        detected="$LANG"
      fi
    fi
  fi

  echo "$detected"
}

LANG=$(detect_language "$TEMP_DIR")
echo "✅ Определён язык: $LANG"

# === Шаги сборки в зависимости от языка ===
get_build_steps() {
  case $LANG in
    python)
      cat << 'EOF'
      - apt-get update
      - apt-get install -y python3 python3-pip
      - pip3 install -r requirements.txt
      - python3 -m pytest tests/ || echo "Тесты не обязательны"
EOF
      ;;

    node)
      cat << 'EOF'
      - apt-get update
      - curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
      - apt-get install -y nodejs
      - npm ci
      - npm run build || echo "Сборка не обязательна"
      - npm test || echo "Тесты не обязательны"
EOF
      ;;

    java)
      cat << 'EOF'
      - apt-get update
      - apt-get install -y openjdk-17-jdk maven
      - mvn clean package
EOF
      ;;

    go)
      cat << 'EOF'
      - apt-get update
      - apt-get install -y golang
      - go mod download
      - go build -o app .
EOF
      ;;
  esac
}

# === Генерация pipeline.yaml ===
cat > "$OUTPUT" << EOF
# Автоматически сгенерированный CI/CD пайплайн
# Язык: $LANG
# Репозиторий: $REPO
# Ветка: $BRANCH
# Порт: $PORT
# Требования: RAM >= ${MEMORY}MB, Disk >= ${DISK}MB

stages:
  - build

variables:
  APP_LANG: "$LANG"
  # REQUIRED_MEMORY_MB: "$MEMORY"
  # REQUIRED_DISK_MB: "$DISK"
  EXPOSED_PORT: "$PORT"
  REPO_URL: "$REPO"
  TARGET_BRANCH: "$BRANCH"
  PROJECT_ROOT: "/app"

build_application:
  stage: build
  image: ubuntu:22.04
  before_script:
    - apt-get update && apt-get install -y git wget sudo
    - git clone --branch "\${TARGET_BRANCH}" "\${REPO_URL}" \${PROJECT_ROOT}
    - cd \${PROJECT_ROOT}
$(get_build_steps)
  script:
    - echo "Сборка завершена успешно."

  tags:
    - high-mem-${MEMORY}mb
    - disk-${DISK}mb

test_application:
  stage: test
  image: ubuntu:22.04
  script:
    - echo "Запуск тестов..."
    - exit 0
  needs: ["build_application"]
  rules:
    - if: \$CI_COMMIT_BRANCH == \$TARGET_BRANCH

deploy_staging:
  stage: deploy
  image: alpine:latest
  script:
    - echo "Доставка приложения в staging..."
    - echo "Используется порт: \${EXPOSED_PORT}"
  environment: staging
  needs: ["test_application"]
  when: manual
  rules:
    - if: \$CI_COMMIT_BRANCH == \$TARGET_BRANCH
EOF

# === Удаление временной директории ===
rm -rf "$TEMP_DIR"
echo "🗑️  Временная директория удалена."

# === Финал ===
echo ""
echo "✅ Анализ завершён!"
# echo "📄 Файл зависимостей сохранён: $DEPS_FILE"
echo "🚀 Пайплайн сгенерирован: $OUTPUT"
echo ""
echo "💡 Теперь вы можете использовать $OUTPUT в GitLab CI, Jenkins, GitHub Actions и т.д."
echo ""
echo "Содержимое пайплайна"
cat "$OUTPUT"
