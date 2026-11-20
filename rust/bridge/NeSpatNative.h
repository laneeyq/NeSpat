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
