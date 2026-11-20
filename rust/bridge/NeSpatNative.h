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
