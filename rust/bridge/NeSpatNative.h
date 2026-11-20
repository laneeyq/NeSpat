#include <stdint.h>
typedef struct {
    int64_t cycles, design, full, remaining;
} NeSpatBatteryDetails;
NeSpatBatteryDetails nespat_battery_details(void);
double nespat_chip_temperature(void);
#include <stdbool.h>
uint8_t nespat_assess(double battery, int8_t ac, double temperature, int8_t thermal, bool starting);
int64_t nespat_minutes_to_seconds(int64_t minutes);

typedef struct NeSpatSampler NeSpatSampler;
NeSpatSampler *nespat_sampler_create(void);
void nespat_sampler_destroy(NeSpatSampler *sampler);
double nespat_sampler_cpu(NeSpatSampler *sampler);
uint64_t nespat_used_memory(uint64_t page_size);
int8_t nespat_lid_closed(void);
int8_t nespat_sleep_disabled(void);
uint32_t nespat_active_uid(void);
bool nespat_setter_ready(void);
int32_t nespat_setter_lock(void);
bool nespat_setter_run(int32_t lock_fd, bool disabled);
void *nespat_status_create(const void *view_controller);
void nespat_status_title(const void *item, const char *title);
void nespat_status_destroy(void *item);

typedef struct {
    double now, wall, last_time, expires, deadline, maximum;
    bool has_expiry, has_deadline, has_lease, selected_lifetime;
    bool service_verified, authorized, active_user, recovery_only, foreign_owner;
    bool known, boot_matches, known_boot_matches, lease_matches;
    bool start_safe, running_safe, desired, exhausted;
    int8_t lid_closed, sleep_disabled;
} NeSpatAutoObservation;
typedef enum {
    NSAutoOff, NSAutoPrepare, NSAutoKeepActive, NSAutoRestore, NSAutoUnverified,
    NSAutoClock, NSAutoOwnership, NSAutoReplaced, NSAutoLost, NSAutoForeign,
    NSAutoFinished, NSAutoUnauthorized, NSAutoOpenLid, NSAutoUnsafe, NSAutoUnconfirmed
} NeSpatAutoAction;
typedef struct {
    NeSpatAutoAction action;
    bool record_time, adopt_lease, forget_lease, mark_finished;
} NeSpatAutoDecision;
NeSpatAutoDecision nespat_auto_decide(NeSpatAutoObservation observation, bool after_prepare);

#include <CoreFoundation/CFString.h>
#include <CoreFoundation/CFURL.h>
bool nespat_valid_requirement(CFStringRef text);
bool nespat_matches_code(CFURLRef url, CFStringRef text, bool require_hardened);

#include <CoreFoundation/CFDictionary.h>
typedef struct {
    double percent;
    int64_t minutes;
    int8_t external, charging, charged;
} NeSpatPowerSource;
NeSpatPowerSource nespat_current_battery(void);
NeSpatPowerSource nespat_parse_battery(CFDictionaryRef description);
typedef enum { NSRetryReserve, NSRetryWait, NSRetryClockFault, NSRetryRepairClock, NSRetryInvalidHistory } NeSpatRetry;
NeSpatRetry nespat_retry_decision(double now, double since, double last, bool clock_fault,
                                  bool was_emergency, bool emergency, bool manual, double interval);
int32_t nespat_emergency_sleep(void);
void *nespat_presets_create(const void *target);
void nespat_presets_update(const void *control, int64_t minutes, bool enabled);
int64_t nespat_preset_minutes(intptr_t index);

bool nespat_journal_check(int32_t fd, bool directory, uint32_t owner);
int32_t nespat_journal_read(int32_t directory, uint32_t owner, uint8_t *buffer, size_t capacity);
bool nespat_journal_write(int32_t directory, uint32_t owner, const uint8_t *data, size_t size);
void *nespat_battery_grid_create(NeSpatBatteryDetails details);
void nespat_battery_grid_update(const void *grid, NeSpatBatteryDetails details);
bool nespat_login_enabled(bool local_agent, bool installed_panel);
bool nespat_login_set(bool on, bool local_agent, bool installed_panel);
CFStringRef _Nonnull nespat_format_percent(double value) CF_RETURNS_RETAINED;
CFStringRef _Nonnull nespat_format_memory(uint64_t bytes) CF_RETURNS_RETAINED;
CFStringRef _Nonnull nespat_format_duration(double seconds) CF_RETURNS_RETAINED;
int64_t nespat_parse_minutes(const uint8_t * _Nullable bytes, size_t length);
double nespat_deadline(double start, double seconds);
void nespat_xpc_pin(const void * _Nonnull connection, const void * _Nonnull requirement);
void nespat_xpc_listener_pin(const void * _Nonnull listener, const void * _Nonnull requirement);
bool nespat_xpc_root_reply(const void * _Nonnull connection);
bool nespat_xpc_current_client(const void * _Nonnull connection, uint32_t installed_uid);
#include <CoreFoundation/CFData.h>
typedef struct {
    uint8_t id[16], session[16];
    int64_t minutes, sequence;
    uint8_t operation;
    bool has_session, has_minutes, has_sequence;
} NeSpatRequest;
bool nespat_valid_request(const NeSpatRequest * _Nonnull request);
bool nespat_decode_request(const uint8_t * _Nullable bytes, size_t len, NeSpatRequest * _Nonnull request);
CFDataRef _Nullable nespat_encode_request(const NeSpatRequest * _Nonnull request) CF_RETURNS_RETAINED;

typedef struct { uint8_t epoch[16], nonce[16]; } NeSpatHello;
CFDataRef _Nonnull nespat_hello(const NeSpatHello * _Nonnull hello, bool response) CF_RETURNS_RETAINED;
bool nespat_read_hello(CFDataRef _Nonnull bytes, bool response, NeSpatHello * _Nonnull out);
CFDataRef _Nullable nespat_operation(CFDataRef _Nonnull bytes, const uint8_t * _Nonnull epoch, bool unwrap) CF_RETURNS_RETAINED;

typedef struct { uint8_t epoch[16], id[16]; } NeSpatCorrelation;
CFDataRef _Nullable nespat_reply(CFDataRef _Nonnull bytes, const NeSpatCorrelation * _Nonnull key, bool unwrap) CF_RETURNS_RETAINED;
typedef struct NeSpatTransport NeSpatTransport;
NeSpatTransport * _Nonnull nespat_transport_new(void);
void nespat_transport_drop(NeSpatTransport * _Nonnull t);
void nespat_transport_close(NeSpatTransport * _Nonnull t);
uint8_t nespat_transport_phase(const NeSpatTransport * _Nonnull t);
bool nespat_transport_start(NeSpatTransport * _Nonnull t);
bool nespat_transport_arm(NeSpatTransport * _Nonnull t, double now, double timeout);
bool nespat_transport_timely(const NeSpatTransport * _Nonnull t, double now);
bool nespat_transport_verify(NeSpatTransport * _Nonnull t, int32_t pid, uint32_t uid);
bool nespat_transport_peer(const NeSpatTransport * _Nonnull t, int32_t pid, uint32_t uid);
bool nespat_transport_reserve(NeSpatTransport * _Nonnull t, const uint8_t * _Nonnull id, bool has_sequence, int64_t sequence);
bool nespat_boot(uint8_t * _Nonnull out);
bool nespat_matches_host(CFStringRef _Nonnull model, CFStringRef _Nonnull build);
typedef struct { uint32_t uid; uint64_t seconds, micros; } NeSpatProcessStamp;
int8_t nespat_snapshot(int32_t pid, NeSpatProcessStamp * _Nonnull out);
double nespat_continuous_seconds(void);
typedef struct { uint8_t epoch[16], boot[16], setup[16]; double continuous; int32_t pid; } NeSpatPulse;
bool nespat_publish_pulse(NeSpatPulse * _Nonnull value, bool watchdog);
bool nespat_read_pulse(NeSpatPulse * _Nonnull value, bool watchdog);
CFStringRef _Nonnull nespat_journal_digest(CFDataRef _Nonnull bytes) CF_RETURNS_RETAINED;
CFDataRef _Nullable nespat_journal_integrity(CFDataRef _Nonnull bytes, bool unwrap) CF_RETURNS_RETAINED;
typedef struct { int32_t directory, lock; } NeSpatJournalFiles;
bool nespat_open_journal(CFStringRef _Nonnull path, uint32_t owner, NeSpatJournalFiles * _Nonnull out);
bool nespat_open_pinned_journal(int32_t fd, uint32_t owner, NeSpatJournalFiles * _Nonnull out);
typedef struct {
    double expiry, last_observation, last_heartbeat, timeout;
    bool has_expiry, has_observation, has_heartbeat, has_timeout, full;
} NeSpatAuthorityClock;
bool nespat_authority_expired(const NeSpatAuthorityClock * _Nonnull grant, double now);
bool nespat_valid_grant(double issued, double expires, double maximum);
typedef struct NeSpatReplayLedger NeSpatReplayLedger;
NeSpatReplayLedger * _Nonnull nespat_ledger_new(void);
void nespat_ledger_drop(NeSpatReplayLedger * _Nonnull ledger);
typedef struct {
    uint8_t id[16];
    int64_t sequence, last_sequence;
    uint32_t requests;
    bool has_sequence, selected, matching_session, recovery;
} NeSpatRequestAdmission;
uint8_t nespat_admit_request(NeSpatReplayLedger * _Nonnull ledger, NeSpatRequestAdmission * _Nonnull request);
CFStringRef _Nullable nespat_code_pin(CFStringRef _Nonnull hash, CFStringRef _Nonnull identifier) CF_RETURNS_RETAINED;
typedef struct NeSpatProfile NeSpatProfile;
typedef struct { uint8_t setup[16]; uint32_t uid; double trial_expires;
    bool exclusive, selected, trial, on_battery, acceptance, acceptance_only;
} NeSpatProfileInfo;
NeSpatProfile * _Nullable nespat_profile_load(NeSpatProfileInfo * _Nonnull info);
void nespat_profile_drop(NeSpatProfile * _Nonnull profile);
bool nespat_profile_enabled(const NeSpatProfile * _Nonnull profile);
bool nespat_profile_host(const NeSpatProfile * _Nonnull profile);
CFStringRef _Nonnull nespat_profile_hash(const NeSpatProfile * _Nonnull profile, bool helper) CF_RETURNS_RETAINED;
