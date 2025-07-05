#!/bin/bash

# --- НАСТРОЙКИ ---
# Массив имен Docker-контейнеров с PostgreSQL
CONTAINER_NAMES=("remnawave-db" "remnawave-tg-shop-db-trib")
# Пользователь PostgreSQL (может быть разным для каждого контейнера)
DB_USER="postgres"
# Директория для хранения бэкапов на хост-машине
BACKUP_DIR="/opt/r2_backup/pg_backups"
# Количество дней, которое нужно хранить бэкапы
DAYS_TO_KEEP=7
# Логирование
LOG_FILE="$BACKUP_DIR/backup.log"
# --- КОНЕЦ НАСТРОЕК ---

# Создаем директорию для бэкапов, если она не существует
mkdir -p "$BACKUP_DIR"

# Функция логирования
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Функция проверки существования контейнера
check_container_exists() {
    local container_name="$1"
    if ! docker ps -q -f name="^${container_name}$" | grep -q .; then
        log_message "ПРЕДУПРЕЖДЕНИЕ: Контейнер '$container_name' не найден или не запущен"
        return 1
    fi
    return 0
}

# Функция проверки доступности PostgreSQL в контейнере
check_postgres_ready() {
    local container_name="$1"
    local db_user="$2"
    
    if ! docker exec "$container_name" pg_isready -U "$db_user" >/dev/null 2>&1; then
        log_message "ОШИБКА: PostgreSQL в контейнере '$container_name' недоступен"
        return 1
    fi
    return 0
}

# Функция создания бэкапа для одного контейнера
backup_container() {
    local container_name="$1"
    local db_user="$2"
    
    log_message "Начало резервного копирования контейнера: $container_name"
    
    # Проверяем существование контейнера
    if ! check_container_exists "$container_name"; then
        return 1
    fi
    
    # Проверяем доступность PostgreSQL
    if ! check_postgres_ready "$container_name" "$db_user"; then
        return 1
    fi
    
    # Формируем имя файла с текущей датой и временем + имя контейнера
    local backup_filename="${container_name}-backup-$(date +%Y-%m-%d_%H-%M-%S).sql.zst"
    local backup_full_path="$BACKUP_DIR/$backup_filename"
    
    # Выполняем резервное копирование
    if docker exec "$container_name" pg_dumpall -U "$db_user" | zstd -c > "$backup_full_path"; then
        # Проверяем, что файл создан и не пустой
        if [ -s "$backup_full_path" ]; then
            local file_size=$(du -h "$backup_full_path" | cut -f1)
            log_message "✅ Бэкап '$container_name' успешно создан: $backup_full_path (размер: $file_size)"
            return 0
        else
            log_message "❌ ОШИБКА: Файл бэкапа '$container_name' пуст или поврежден"
            rm -f "$backup_full_path"
            return 1
        fi
    else
        log_message "❌ ОШИБКА: Не удалось создать бэкап для контейнера '$container_name'"
        rm -f "$backup_full_path"
        return 1
    fi
}

# Функция очистки старых бэкапов для конкретного контейнера
cleanup_old_backups() {
    local container_name="$1"
    log_message "Удаление старых бэкапов для контейнера '$container_name' (старше $DAYS_TO_KEEP дней)..."
    
    local deleted_count=$(find "$BACKUP_DIR" -type f -name "${container_name}-backup-*.sql.zst" -mtime +"$DAYS_TO_KEEP" -exec rm -f {} \; -print | wc -l)
    
    if [ "$deleted_count" -gt 0 ]; then
        log_message "Удалено $deleted_count старых бэкапов для '$container_name'"
    else
        log_message "Старые бэкапы для '$container_name' не найдены"
    fi
}

# Основная логика
log_message "=== НАЧАЛО ПРОЦЕССА РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
log_message "Контейнеры для обработки: ${CONTAINER_NAMES[*]}"

# Счетчики для статистики
successful_backups=0
failed_backups=0
total_containers=${#CONTAINER_NAMES[@]}

# Обрабатываем каждый контейнер
for container_name in "${CONTAINER_NAMES[@]}"; do
    log_message "--- Обработка контейнера: $container_name ---"
    
    if backup_container "$container_name" "$DB_USER"; then
        ((successful_backups++))
        # Очищаем старые бэкапы для этого контейнера
        cleanup_old_backups "$container_name"
    else
        ((failed_backups++))
    fi
    
    log_message ""
done

# Общая очистка (на случай если остались файлы со старыми именами)
log_message "--- Общая очистка старых бэкапов ---"
find "$BACKUP_DIR" -type f -name "backup-*.sql.zst" -mtime +"$DAYS_TO_KEEP" -exec rm -f {} \;

# Финальная статистика
log_message "=== ЗАВЕРШЕНИЕ ПРОЦЕССА РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
log_message "Общая статистика:"
log_message "📊 Всего контейнеров: $total_containers"
log_message "✅ Успешных бэкапов: $successful_backups"
log_message "❌ Неудачных бэкапов: $failed_backups"

# Показываем текущие бэкапы
log_message "--- Текущие бэкапы в директории ---"
ls -lah "$BACKUP_DIR"/*.sql.zst 2>/dev/null | while read line; do
    log_message "$line"
done

# Код завершения
if [ "$failed_backups" -eq 0 ]; then
    log_message "🎉 Все бэкапы созданы успешно!"
    exit 0
else
    log_message "⚠️  Процесс завершен с ошибками. Проверьте лог выше."
    exit 1
fi
