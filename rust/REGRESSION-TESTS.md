# Проверки безопасности NeSpat 1.2.1

База сравнения — дерево тестов в коммите `4aa0673`. Одна строка таблицы объединяет сценарии с одинаковым наблюдаемым результатом. Число тестовых функций не измеряет эквивалентность двух реализаций.

| Что проверяли в прежней версии | Где воспроизведено в Rust |
| --- | --- |
| ExactCodePin, SigningPolicyContract, LocalAutomaticTrust, XPCAdmission, XPCRejection, ListenerBoundary | `signing.rs`, `profile.rs`, `service_listener.rs`. Системная проверка подписи, два направления проверки XPC, путь исполняемого файла и идентичность процесса. |
| TransportBoundary, HeartbeatWire, TransportStateMachine, AcceptanceRPCProbe | `request.rs`, `wire.rs`, `transport.rs`, `service_listener.rs`. Корреляция, допустимые поля, порядок запросов, потеря канала, повторы. |
| Engine, GrantLifetimePolicy, Heartbeat, OwnerGrant, FreshConsent, UnprovenConsent, LeaseBoundaryRace | `authority.rs`, `service_engine/tests/regression.rs`. Проверки до и после операции, владелец, согласованность журнала, сроки и повторное использование разрешения. |
| AutonomousRetry, MonotonicRetry, PersistentCooldown, ClockAuthority, ClockProgress, ExclusiveRecovery, CriticalRecovery, RecoveryEntryPoint | `recovery.rs`, `service_engine/tests/regression.rs`. Скачки часов, аварийное восстановление, ручной запрос, независимый наблюдатель и перезапуски с тем же журналом. |
| LiveFile, OwnedPending, ControllerRace, ManualRequest, IndependentWatch, InheritedSetterLock | `service_store.rs`, `service_engine/tests/regression.rs`, `setter.rs`. Проверяются журнал текущего формата, идентичность объекта блокировки и наследование блокировки дочерним процессом. |
| SensorAssessment, SystemAdapter, ServerSafety, StrictSensorPolicy, ThermalDefault, TMaxBaseline | `policy.rs`, `battery.rs`, `lib.rs`, `service_engine/tests/regression.rs`. Пороговые и неопределённые показания, возвращение обычного сна и запрос аварийного сна. |
| AutomaticSession, HelperSessionModel, IncompleteSessionQuit, JournalLossQuit, DisplayPolicy, Countdown, CustomDuration, PanelLayout | `driver.rs`, `automatic.rs`, `policy.rs`, `format.rs`, `panel_readings.rs`. Дополнительно `scripts/test.sh` отрисовывает реальную панель AppKit и проверяет её размеры. |
| Предусловия удаления, проверка устанавливаемого кода, порядок остановки служб | `bin/setup.rs`, `service_host.rs`, `service_store.rs`. Ошибка на любой из проверок или при остановке прерывает последовательность до удаления файлов. |

Обычный пользователь macOS с графическим сеансом может выполнить `bash scripts/test.sh` и `cargo test --locked --release --manifest-path rust/Cargo.toml`. Для проверок XPC нужен доступ к локальным механизмам macOS. Проверки движка подставляют результаты операций питания и отказов. Файловые проверки используют временные каталоги. Тесты XPC поднимают отдельный анонимный listener.

Сценарии, относящиеся исключительно к старому PKG, формату диагностических отчётов, отдельному тестовому контроллеру или прежнему ограничению сессии в 12 часов, не описывают выпуск 1.2.1. Полный цикл переустановки, остановка системных launchd-служб и физический сон требуют отдельной проверки на Mac. Таблица описывает соответствие по поведению и не подтверждает построчного совпадения всех прежних тестов.
