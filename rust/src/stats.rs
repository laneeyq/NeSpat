use libc::*;
use std::{mem, ptr, slice};

// mach_host_self returns a send right for each call.
extern "C" {
    fn mach_port_deallocate(task: mach_port_t, name: mach_port_t) -> kern_return_t;
}

struct Host(mach_port_t);
impl Host {
    fn new() -> Self {
        Self(unsafe { mach_host_self() })
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        unsafe {
            mach_port_deallocate(mach_task_self(), self.0);
        }
    }
}

fn ticks() -> Option<Vec<u32>> {
    let host = Host::new();
    let mut cpus = 0;
    let mut count = 0;
    let mut info = ptr::null_mut();
    let status = unsafe {
        host_processor_info(
            host.0,
            PROCESSOR_CPU_LOAD_INFO,
            &mut cpus,
            &mut info,
            &mut count,
        )
    };
    if status != KERN_SUCCESS || info.is_null() {
        return None;
    }
    let length = cpus as usize * CPU_STATE_MAX as usize;
    let result = (length != 0 && length <= count as usize)
        .then(|| unsafe { slice::from_raw_parts(info.cast::<u32>(), length) }.to_vec());
    unsafe {
        vm_deallocate(
            mach_task_self(),
            info as usize,
            count as usize * mem::size_of::<integer_t>(),
        );
    }
    result
}

fn usage(current: &[u32], previous: &[u32]) -> Option<f64> {
    if current.is_empty()
        || current.len() != previous.len()
        || !current.len().is_multiple_of(CPU_STATE_MAX as usize)
    {
        return None;
    }
    let mut total = 0u64;
    let mut idle = 0u64;
    for (index, (&now, &before)) in current.iter().zip(previous).enumerate() {
        let delta = u64::from(now.wrapping_sub(before));
        total += delta;
        if index % CPU_STATE_MAX as usize == CPU_STATE_IDLE as usize {
            idle += delta;
        }
    }
    Some(if total == 0 {
        0.0
    } else {
        (total - idle) as f64 / total as f64 * 100.0
    })
}

pub struct Sampler {
    previous: Vec<u32>,
}

#[no_mangle]
pub extern "C" fn nespat_sampler_create() -> *mut Sampler {
    Box::into_raw(Box::new(Sampler {
        previous: Vec::new(),
    }))
}
#[no_mangle]
pub unsafe extern "C" fn nespat_sampler_destroy(sampler: *mut Sampler) {
    if !sampler.is_null() {
        drop(Box::from_raw(sampler));
    }
}
#[no_mangle]
pub unsafe extern "C" fn nespat_sampler_cpu(sampler: *mut Sampler) -> f64 {
    let Some(sampler) = sampler.as_mut() else {
        return f64::NAN;
    };
    let Some(current) = ticks() else {
        return f64::NAN;
    };
    let percent = usage(&current, &sampler.previous);
    sampler.previous = current;
    percent.unwrap_or(f64::NAN)
}
#[no_mangle]
pub extern "C" fn nespat_used_memory(page_size: u64) -> u64 {
    let host = Host::new();
    let mut stats = mem::MaybeUninit::<vm_statistics64>::zeroed();
    let mut count = HOST_VM_INFO64_COUNT;
    let status = unsafe {
        host_statistics64(
            host.0,
            HOST_VM_INFO64,
            stats.as_mut_ptr().cast(),
            &mut count,
        )
    };
    if status != KERN_SUCCESS || count < HOST_VM_INFO64_COUNT {
        return 0;
    }
    let stats = unsafe { stats.assume_init() };
    let pages = u64::from(stats.active_count)
        + u64::from(stats.wire_count)
        + u64::from(stats.compressor_page_count);
    pages.saturating_mul(page_size)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sample_deltas_handle_wrap_and_cpu_topology_changes() {
        assert_eq!(usage(&[1, 0, 4, 0], &[u32::MAX, 0, 2, 0]), Some(50.0));
        assert_eq!(usage(&[1; 4], &[1; 4]), Some(0.0));
        assert_eq!(usage(&[1; 8], &[1; 4]), None);
    }
}
