# Dates are checked against independent reference values, so these tests call the
# helpers directly rather than through an API name.
using Test
using ChainTables: ChainTables, TransportError

const DATES = ChainTables

const AMZ_DATE_CASES = [
    (name = "epoch", t = 0, amz = "19700101T000000Z"),
    (name = "AWS example", t = 1369353600, amz = "20130524T000000Z"),
    (name = "leap day of a leap century", t = 951782400, amz = "20000229T000000Z"),
    (name = "2023", t = 1700000000, amz = "20231114T221320Z"),
]

@testset "amz_date: $(case.name)" for case in AMZ_DATE_CASES
    @test DATES.amz_date(case.t) == case.amz
end

const ROUND_TRIP_TIMES = [0, 86399, 951782400, 1700000000, 4102444800]

@testset "days_from_civil inverts civil_from_days at $t" for t in ROUND_TRIP_TIMES
    y, m, d = DATES.civil_from_days(fld(t, 86400))
    @test DATES.days_from_civil(y, m, d) * 86400 + mod(t, 86400) == t
end

@testset "parse_http_date reads Last-Modified" begin
    @test DATES.parse_http_date("Wed, 12 Oct 2009 17:50:00 GMT") == 1255369800
    says = "cannot parse the Last-Modified header"
    @test_throws TransportError says DATES.parse_http_date("yesterday")
    @test_throws TransportError says DATES.parse_http_date("Wed, 12 Foo 2009 17:50:00 GMT")
end

@testset "parse_iso_date reads LastModified" begin
    @test DATES.parse_iso_date("2009-10-12T17:50:00.000Z") == 1255369800
    @test DATES.parse_iso_date("2009-10-12T17:50:00Z") == 1255369800
    says = "cannot parse the LastModified value"
    @test_throws TransportError says DATES.parse_iso_date("2009-10-12")
end
