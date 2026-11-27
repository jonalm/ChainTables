# The two date forms of an S3 response: `Wed, 12 Oct 2009 17:50:00 GMT` (a HEAD's
# `Last-Modified`) and `2009-10-12T17:50:30.000Z` (a listing's `LastModified`).
const HTTP_DATE = r"\A\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d\d):(\d\d):(\d\d) GMT\z"
const ISO_DATE = r"\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?Z\z"

const MONTHS = Dict(
    "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4, "May" => 5, "Jun" => 6,
    "Jul" => 7, "Aug" => 8, "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12,
)

# Whole Unix seconds, which is all that `ObjectMeta.modified` promises, or `nothing` for
# a text in another form.
function try_parse_http_date(text::AbstractString)
    m = match(HTTP_DATE, strip(text))
    m === nothing && return nothing
    month = get(MONTHS, m[2], nothing)
    month === nothing && return nothing
    day, year, hour, minute, second = captured_ints(m, [1, 3, 4, 5, 6])
    return unix_seconds(year, month, day, hour * 3600 + minute * 60 + second)
end

function try_parse_iso_date(text::AbstractString)
    m = match(ISO_DATE, strip(text))
    m === nothing && return nothing
    year, month, day, hour, minute, second = captured_ints(m, 1:6)
    return unix_seconds(year, month, day, hour * 3600 + minute * 60 + second)
end

captured_ints(m::RegexMatch, groups) = map(group -> parse(Int, m[group]), groups)

function unix_seconds(year::Integer, month::Integer, day::Integer, seconds::Integer)
    return Int64(days_from_civil(year, month, day)) * 86400 + seconds
end

# Howard Hinnant's `days_from_civil`, with the names of his paper: the count of days
# since 1970-01-01 of a date, with no calendar library.
function days_from_civil(year::Integer, month::Integer, day::Integer)
    y = year - (month <= 2)
    era = fld(y, 400)
    yoe = y - era * 400
    doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) ÷ 5 + day - 1
    doe = yoe * 365 + yoe ÷ 4 - yoe ÷ 100 + doy
    return era * 146097 + doe - 719468
end
