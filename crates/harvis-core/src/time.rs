use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use crate::error::HarvisResult;

pub fn now_rfc3339() -> HarvisResult<String> {
    Ok(OffsetDateTime::now_utc().format(&Rfc3339)?)
}
