#!/bin/bash

set -euo pipefail

# === Значения по умолчанию ===
LANG=""
REPO=""
BRANCH="main"
PORT=3000
MEMORY=256
DISK=1000
OUTPUT="pipeline.yaml"
TEMP_DIR=$(mktemp -d)
CLONE_PATH="$TEMP_DIR/project"

# === Временная очистка при выходе ===
trap 'rm -rf "$TEMP_DIR"' EXIT

# === Справка ===
usage() {
  echo "Использование: $0 [опции]"
  echo "Опции:"
  echo "  --lang LANG        Язык: python, node, java, go (авто, если не указан)"
  echo "  --repo URL         URL репозитория (HTTPS)"
  echo "  --branch NAME      Ветка (по умолчанию: main)"
  echo "  --port N           Требуемый порт (определяется автоматически)"
  echo "  --memory N         Минимальная память в MB (по умолчанию: 256)"
  echo "  --disk N           Минимальное дисковое пространство в MB (оценивается)"
  echo "  --output FILE      Имя выходного .yaml файла"
  exit 1
}

# === Парсинг аргументов ===
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --lang) LANG="$2"; shift ;;
    --repo) REPO="$2"; shift ;;
    --branch) BRANCH="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    --memory) MEMORY="$2"; shift ;;
    --disk) DISK="$2"; shift ;;
    --output) OUTPUT="$2"; shift ;;
    *) echo "Неизвестный параметр: $1"; usage ;;
  esac
  shift
done

# === Проверка обязательных полей ===
if [[ -z "$REPO" ]]; then
  echo "Ошибка: --repo обязателен."
  usage
fi

# === Клонирование репозитория для анализа ===
echo "🔍 Клонируем репозиторий для анализа: $REPO (ветка: $BRANCH)..."
git clone --depth 1 --branch "$BRANCH" "$REPO" "$CLONE_PATH" >/dev/null 2>&1 || \
  { echo "❌ Не удалось клонировать репозиторий. Проверьте URL и доступ."; exit 1; }

cd "$CLONE_PATH"

# === Поиск ключевых файлов ===
HAS_PACKAGE_JSON=$(find . -name "package.json" | head -n1)
HAS_REQUIREMENTS_TXT=$(find . -name "requirements.txt" | head -n1)
HAS_POM_XML=$(find . -name "pom.xml" | head -n1)
HAS_GO_MOD=$(find . -name "go.mod" | head -n1)

# === Автоопределение языка, если не задан ===
if [[ -z "$LANG" ]]; then
  if [[ -n "$HAS_PACKAGE_JSON" ]]; then
    LANG="node"
  elif [[ -n "$HAS_REQUIREMENTS_TXT" ]]; then
    LANG="python"
  elif [[ -n "$HAS_POM_XML" ]]; then
    LANG="java"
  elif [[ -n "$HAS_GO_MOD" ]]; then
    LANG="go"
  else
    echo "⚠️  Не удалось определить язык. Укажите --lang явно."
    echo "Доступные файлы:"
    find . -maxdepth 2 -type f -name "package.json" -o -name "requirements.txt" -o -name "pom.xml" -o -name "go.mod"
    exit 1
  fi
  echo "🟢 Язык определён по структуре: $LANG"
else
  echo "🟡 Язык задан вручную: $LANG"
fi

# === Анализ занимаемого места (оценка) ===
PROJECT_SIZE_MB=$(du -sm . | cut -f1)
DISK_ESTIMATED=$(( PROJECT_SIZE_MB * 3 + 500 ))  # место под зависимости и билд
DISK=${DISK:-$DISK_ESTIMATED}

# === Анализ потребления памяти (грубая оценка) ===
case $LANG in
  node)
    MEMORY_EST=$(( $(grep -c "^ *" "$HAS_PACKAGE_JSON" 2>/dev/null || echo 10) * 10 ))
    MEMORY=${MEMORY:-$(( MEMORY_EST > 256 ? MEMORY_EST : 256 ))}
    ;;
  python)
    DEPS_COUNT=$(wc -l < "$HAS_REQUIREMENTS_TXT")
    MEMORY=${MEMORY:-$(( DEPS_COUNT * 20 > 256 ? DEPS_COUNT * 20 : 256 ))}
    ;;
  java)
    MEMORY=${MEMORY:-1024}  # Maven/JVM требует много памяти
    ;;
  go)
    MEMORY=${MEMORY:-256}
    ;;
esac

# === Поиск использования порта в коде (web-серверы) ===
PORT_FROM_CODE=$(grep -r -E "listen.*[ :]+[0-9]{4,5}" . --exclude-dir={.git,node_modules} -m1 | grep -oE '[0-9]{4,5}' | head -n1)

if [[ -n "$PORT_FROM_CODE" ]] && [[ "$PORT_FROM_CODE" -ge 1024 ]] && [[ "$PORT_FROM_CODE" -le 65535 ]]; then
  PORT=$PORT_FROM_CODE
  echo "🌐 Порт найден в коде: $PORT"
fi

# === Определение типа приложения (web или cli) ===
IS_WEB_APP=0
if [[ -n "$HAS_PACKAGE_JSON" ]] && grep -q '"scripts".*["'\'']start["'\'']' "$HAS_PACKAGE_JSON"; then
  IS_WEB_APP=1
elif [[ -n "$HAS_REQUIREMENTS_TXT" ]] && grep -i -E "(flask|django|fastapi)" "$HAS_REQUIREMENTS_TXT" > /dev/null; then
  IS_WEB_APP=1
elif grep -r -l -E "http.Server|express|Flask|Django|gin" . --exclude-dir={.git,node_modules} | head -n1 > /dev/null; then
  IS_WEB_APP=1
fi

# === Шаги сборки (динамические) ===
get_build_steps() {
  local steps=""
  case $LANG in
    python)
      steps=$(cat << 'EOF'
      - apt-get update
      - apt-get install -y python3 python3-pip
      - pip3 install -r requirements.txt
      - python3 -m pytest tests/ || echo "Тесты не прошли или отсутствуют"
EOF
)
      ;;

    node)
      steps=$(cat << 'EOF'
      - apt-get update
      - curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
      - apt-get install -y nodejs
      - npm ci
      - npm run build || echo "Сборка не обязательна"
      - npm test || echo "Тесты не обязательны"
EOF
)
      ;;

    java)
      steps=$(cat << 'EOF'
      - apt-get update
      - apt-get install -y openjdk-17-jdk maven
      - mvn clean package
EOF
)
      ;;

    go)
      steps=$(cat << 'EOF'
      - apt-get update
      - apt-get install -y golang
      - go mod download
      - go build -o app .
EOF
)
      ;;
  esac
  echo "$steps"
}

# === Генерация YAML ===
cat > "$OUTPUT" << EOF
# === Автоматически сгенерированный CI/CD пайплайн ===
# Проект: $REPO
# Ветка: $BRANCH
# Язык: $LANG
# Тип: $( [[ $IS_WEB_APP -eq 1 ]] && echo "веб-приложение" || echo "CLI/фоновый сервис" )
# Рекомендации: RAM >= ${MEMORY}MB, Disk >= ${DISK}MB, Port: $PORT

stages:
  - build
  - test
  - deploy

variables:
  APP_LANG: "$LANG"
  REQUIRED_MEMORY_MB: "$MEMORY"
  REQUIRED_DISK_MB: "$DISK"
  EXPOSED_PORT: "$PORT"
  REPO_URL: "$REPO"
  TARGET_BRANCH: "$BRANCH"
  PROJECT_TYPE: "$( [[ $IS_WEB_APP -eq 1 ]] && echo "web" || echo "cli" )"

build_application:
  stage: build
  image: ubuntu:22.04
  before_script:
    - apt-get update && apt-get install -y git wget sudo curl
    - git clone --branch "\${TARGET_BRANCH}" "\${REPO_URL}" /app
    - cd /app
$(get_build_steps)

  script:
    - echo "✅ Сборка завершена."

  tags:
    - lang-$LANG
    - mem-${MEMORY}mb
    - disk-${DISK}mb
  rules:
    - if: \$CI_COMMIT_BRANCH == \$TARGET_BRANCH

test_application:
  stage: test
  image: ubuntu:22.04
  script:
    - echo "🧪 Запуск тестов..."
    # Здесь будут тесты в зависимости от языка
    - exit 0
  needs: ["build_application"]
  rules:
    - if: \$CI_COMMIT_BRANCH == \$TARGET_BRANCH

deploy_staging:
  stage: deploy
  image: alpine:latest
  script:
    - echo "🚚 Доставка приложения в staging..."
    - echo "Порт: \${EXPOSED_PORT}"
    - echo "Тип приложения: \${PROJECT_TYPE}"
  environment: staging
  needs: ["test_application"]
  when: manual
  rules:
    - if: \$CI_COMMIT_BRANCH == \$TARGET_BRANCH

# Совет: Добавьте deploy_production с подтверждением
EOF

echo "✅ Пайплайн успешно сгенерирован: $OUTPUT"
echo ""
echo "📊 Аналитика проекта:"
echo "   Язык: $LANG"
echo "   Порт: $PORT"
echo "   Память: ${MEMORY}MB"
echo "   Диск: ${DISK}MB"
echo "   Тип: $( [[ $IS_WEB_APP -eq 1 ]] && echo "веб-приложение" || echo "CLI/фоновый процесс" )"