//! Privacy-safe timings for search work; never records keywords or event IDs.

use std::{collections::BTreeMap, time::Instant};

use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
pub(super) struct SearchReport {
    pub(super) operation: &'static str,
    pub(super) room_scoped: bool,
    pub(super) total_us: u64,
    pub(super) phases_us: BTreeMap<&'static str, u64>,
    pub(super) counts: BTreeMap<&'static str, usize>,
}

pub(super) struct SearchMetrics {
    started: Instant,
    report: SearchReport,
}

impl SearchMetrics {
    pub(super) fn new(operation: &'static str, room_scoped: bool) -> Self {
        Self {
            started: Instant::now(),
            report: SearchReport {
                operation,
                room_scoped,
                total_us: 0,
                phases_us: BTreeMap::new(),
                counts: BTreeMap::new(),
            },
        }
    }

    pub(super) fn phase(&mut self, name: &'static str, started: Instant) {
        let elapsed = started.elapsed().as_micros().min(u64::MAX as u128) as u64;
        *self.report.phases_us.entry(name).or_default() += elapsed;
    }

    pub(super) fn accumulated_us(&mut self, name: &'static str, elapsed: u64) {
        *self.report.phases_us.entry(name).or_default() += elapsed;
    }

    pub(super) fn count(&mut self, name: &'static str, count: usize) {
        *self.report.counts.entry(name).or_default() += count;
    }
}

impl Drop for SearchMetrics {
    fn drop(&mut self) {
        self.report.total_us = self.started.elapsed().as_micros().min(u64::MAX as u128) as u64;
        if let Ok(json) = serde_json::to_string(&self.report) {
            super::app_log("debug", "search_perf", json);
        }
        #[cfg(test)]
        if let Ok(mut reports) = REPORTS.lock() {
            reports.push(self.report.clone());
        }
    }
}

#[cfg(test)]
static REPORTS: std::sync::Mutex<Vec<SearchReport>> = std::sync::Mutex::new(Vec::new());

#[cfg(test)]
pub(super) fn take_reports() -> Vec<SearchReport> {
    REPORTS
        .lock()
        .map(|mut reports| std::mem::take(&mut *reports))
        .unwrap_or_default()
}
