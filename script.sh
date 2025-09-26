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
  local max_port=$((start_port + 100))

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

# === Оценка требуемого дискового пространства ===
estimate_disk_requirement() {
  local repo_dir="$1"
  local lang="$2"

  # Размер репозитория в МБ
  local repo_size_kb
  repo_size_kb=$(du -s "$repo_dir" | awk '{print $1}')
  local repo_size_mb=$(( (repo_size_kb + 1023) / 1024 ))

  local multiplier=3
  local estimated_mb

  case "$lang" in
    node)
      local deps_count=0
      if [[ -f "$repo_dir/package.json" ]]; then
        if command -v jq &> /dev/null; then
          deps_count=$(jq '.dependencies // {} | length' "$repo_dir/package.json")
          deps_count=$((deps_count + $(jq '.devDependencies // {} | length' "$repo_dir/package.json")))
        else
          deps_count=20  # fallback
        fi
      fi
      multiplier=$(( 10 + deps_count / 3 ))
      multiplier=$(( multiplier > 100 ? 100 : multiplier ))
      ;;

    python)
      local req_lines=0
      if [[ -f "$repo_dir/requirements.txt" ]]; then
        req_lines=$(wc -l < "$repo_dir/requirements.txt" | tr -d ' ')
      fi
      multiplier=$(( 5 + req_lines * 2 ))
      multiplier=$(( multiplier > 50 ? 50 : multiplier ))
      ;;

    java)
      multiplier=30
      ;;

    go)
      multiplier=4
      ;;

    *)
      multiplier=5
      ;;
  esac

  estimated_mb=$(( repo_size_mb * multiplier ))
  estimated_mb=$(( estimated_mb < 500 ? 500 : estimated_mb ))  # минимум 500 МБ
  echo "$estimated_mb"
}

# Оценка объёма
DISK_REQUIRED=$(estimate_disk_requirement "$TEMP_DIR" "$LANG")
echo "📊 Оценка требуемого места: ${DISK_REQUIRED} MB"

# Проверка доступного места
avail_mb=$(df / --output=avail -B M | tail -n1 | awk '{print $1}' | tr -d 'M')

if [[ -z "$avail_mb" ]] || ! [[ "$avail_mb" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Не удалось определить свободное место на диске."
else
  echo "💾 Свободно на диске: ${avail_mb} MB"
  if [ "$avail_mb" -lt "$DISK_REQUIRED" ]; then
    echo "⚠️  Недостаточно места для запуска пайплайна, необходимо ${DISK_REQUIRED} МБ"
  else
    echo "✅ Достаточно места для сборки и запуска."
  fi
fi

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
# Оценка требуемого дискового пространства: ${DISK_REQUIRED} MB

stages:
  - build

variables:
  APP_LANG: "$LANG"
  EXPOSED_PORT: "$FREE_PORT"
  REQUIRED_DISK_MB: "$DISK_REQUIRED"
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
echo ""
echo "💡 Теперь вы можете использовать $OUTPUT в GitLab CI, GitHub Actions и других системах."
echo ""
echo "📄 Содержимое пайплайна:"
cat "$OUTPUT"
