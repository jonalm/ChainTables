# Civil dates from Unix seconds and back without loading Dates: Howard Hinnant's
# algorithms. `ObjectMeta.modified` promises whole seconds since the epoch, nothing more.

const MONTHS = Dict(
    "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4, "May" => 5, "Jun" => 6,
    "Jul" => 7, "Aug" => 8, "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12
)

# `Last-Modified: Wed, 12 Oct 2009 17:50:00 GMT`, a HEAD's header.
const HTTP_DATE = r"\A\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d\d):(\d\d):(\d\d) GMT\z"

# `<LastModified>2009-10-12T17:50:30.000Z</LastModified>`, a listing's element.
const ISO_DATE = r"\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?Z\z"

"""
    civil_from_days(days)

Return `(year, month, day)` of the date `days` days after 1970-01-01.
"""
function civil_from_days(days::Integer)
    z = days + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = (doe - doe ÷ 1460 + doe ÷ 36524 - doe ÷ 146096) ÷ 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe ÷ 4 - yoe ÷ 100)
    mp = (5 * doy + 2) ÷ 153
    d = doy - (153 * mp + 2) ÷ 5 + 1
    m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
end

"""
    days_from_civil(year, month, day)

Return the number of days from 1970-01-01 to the date; the inverse of `civil_from_days`.
"""
function days_from_civil(year::Integer, month::Integer, day::Integer)
    y = year - (month <= 2)
    era = fld(y, 400)
    yoe = y - era * 400
    doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) ÷ 5 + day - 1
    doe = yoe * 365 + yoe ÷ 4 - yoe ÷ 100 + doy
    return era * 146097 + doe - 719468
end

function unix_seconds(year, month, day, hour, minute, second)
    return days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
end

"""
    amz_date(unix_seconds)

Return `unix_seconds` as SigV4's `x-amz-date`, `yyyymmddTHHMMSSZ` in UTC.
"""
function amz_date(unix_seconds::Integer)
    days, secs = fldmod(Int64(unix_seconds), 86400)
    y, m, d = civil_from_days(days)
    h, rest = fldmod(secs, 3600)
    mi, s = fldmod(rest, 60)
    return string(y; pad = 4) * string(m; pad = 2) * string(d; pad = 2) * "T" *
        string(h; pad = 2) * string(mi; pad = 2) * string(s; pad = 2) * "Z"
end

"""
    parse_http_date(text)

Return the `Last-Modified` header `text` in whole seconds since the epoch.
"""
function parse_http_date(text::AbstractString)
    m = match(HTTP_DATE, strip(text))
    is_http_date(m) ||
        throw(TransportError("cannot parse the Last-Modified header $(repr(text))"))
    d, month, y, h, mi, s = m.captures
    return unix_seconds(parse_int(y), MONTHS[month], map(parse_int, (d, h, mi, s))...)
end

is_http_date(m) = m !== nothing && haskey(MONTHS, m.captures[2])

"""
    parse_iso_date(text)

Return a listing's `LastModified` value `text` in whole seconds since the epoch.
"""
function parse_iso_date(text::AbstractString)
    m = match(ISO_DATE, strip(text))
    m === nothing &&
        throw(TransportError("cannot parse the LastModified value $(repr(text))"))
    return unix_seconds(map(parse_int, m.captures)...)
end

parse_int(digits) = parse(Int, digits)
