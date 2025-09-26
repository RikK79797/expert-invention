#!/bin/bash

set -euo pipefail

# === Значения по умолчанию ===
LANG=""
REPO=""
BRANCH="main"
PORT=3000
OUTPUT="pipeline.yaml"
TEMP_DIR=".tmp_repo"

# === Список зависимостей ===
DEPS_FILE="dependencies.txt"
echo "Анализ зависимостей:" > "$DEPS_FILE"

# === Функция помощи ===
usage() {
  echo "Использование: $0 [опции]"
  echo "Опции:"
  echo "  --lang LANG        Язык: python, node, java, go (необязательно — автоопределение)"
  echo "  --repo URL         URL репозитория (HTTPS)"
  echo "  --branch NAME      Ветка (по умолчанию: main)"
  echo "  --port N           Базовый порт (по умолчанию: 3000). Если занят — будет найден свободный."
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

# === Проверка корректности номера порта ===
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "Ошибка: Порт должен быть числом от 1 до 65535. Получено: $PORT"
  exit 1
fi

# === Функция поиска свободного порта ===
find_free_port() {
  local start_port=${1}
  local port=$start_port
  local max_port=$((start_port + 100))  # ищем в пределах 100 портов

  # Определяем, какую команду использовать
  local check_cmd="ss -tuln"
  if ! command -v ss &> /dev/null; then
    check_cmd="netstat -tuln"
    if ! command -v netstat &> /dev/null; then
      echo "❌ Не найдены ни 'ss', ни 'netstat'. Установите iproute2 или net-tools."
      exit 1
    fi
  fi

  while [ $port -le $max_port ]; do
    if ! eval "$check_cmd" | grep -q ":$port "; then
      echo "$port"
      return 0
    fi
    ((port++))
  done

  echo "❌ Не найдено свободных портов в диапазоне $start_port-$max_port." >&2
  exit 1
}

# === Поиск свободного порта ===
echo "🔍 Проверка порта $PORT..."
FREE_PORT=$(find_free_port "$PORT")

if [ "$FREE_PORT" -eq "$PORT" ]; then
  echo "✅ Порт $PORT свободен. Используем его."
else
  echo "⚠️  Порт $PORT занят. Используем свободный порт: $FREE_PORT."
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
    rm -rf "$TEMP_DIR"
    exit 1
  fi

  # Если язык задан, проверим совпадение
  if [[ -n "$LANG" ]]; then
    if [[ "$LANG" != "$detected" ]]; then
      echo "⚠️  Предупреждение: Указан язык '$LANG', но обнаружен '$detected' по файлам проекта."
      read -p "Использовать указанный язык? (y/N): " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
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

# === Генерация pipeline.yaml с выбранным свободным портом ===
cat > "$OUTPUT" << EOF
# Автоматически сгенерированный CI/CD пайплайн
# Язык: $LANG
# Репозиторий: $REPO
# Ветка: $BRANCH
# Используемый порт: $FREE_PORT (исходный запрос: $PORT)

stages:
  - build

variables:
  APP_LANG: "$LANG"
  EXPOSED_PORT: "$FREE_PORT"
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

EOF

# === Удаление временной директории ===
rm -rf "$TEMP_DIR"
echo "🗑️  Временная директория удалена."

# === Финальное сообщение ===
echo ""
echo "✅ Анализ завершён!"
echo "🚀 Пайплайн сгенерирован: $OUTPUT"
echo "🔌 Используемый порт: $FREE_PORT"
# echo "📄 Список зависимостей: $DEPS_FILE"
echo ""
echo "💡 Теперь вы можете использовать $OUTPUT в GitLab CI, GitHub Actions и других системах."
echo ""
echo "📄 Содержимое пайплайна:"
cat "$OUTPUT"
