# BestScrap

Polls Best Buy Canada for in-store pickup stock of a product and tells you when
a store gets it (or loses it). No dependencies: `curl` on Linux/macOS/WSL,
PowerShell on Windows.

## Use

```
cp example.config.yml config.yml     # then edit it
./bestscrap.sh                       # Linux, macOS, WSL, Git Bash
bestscrap.bat                        # Windows
```

The first run builds the store list for your provinces (about 30 seconds).
After that it checks every `interval` seconds and prints only changes:

```
[14 Oct. 19:50:05] IN STOCK: Best Buy Express Val d'Or (Val d'Or J9P 5K1) 1801 - 3e Avenue 819-874-0672 - qty 2, reservable
[14 Oct. 20:12:41] QTY CHANGE: Best Buy Express Val d'Or (Val d'Or J9P 5K1) 2 -> 1
[14 Oct. 20:31:09] GONE: Best Buy Express Val d'Or (Val d'Or J9P 5K1) no longer available
```

A sound plays when a store gets stock, including stock that is already there
when you start.

Commands: `watch` (default), `once` (exit code 0 if anything is in stock),
`sync` (rebuild the store list), `stores` (show it).

## Config

See `example.config.yml`. `sku` is the number at the end of the product URL,
`provinces` is a list like `QC, ON` or `ALL`, `sound` is a wav file (empty for
none). The store list is rebuilt automatically when `provinces` or
`extra_seeds` change.

## Notes

- Canada only. It uses bestbuy.ca's own site endpoints, which are undocumented
  and can change or start rate limiting. Keep `interval` reasonable.
- The locations API only returns the stores nearest to a city or postal code,
  so `sync` queries the cities in `seeds.txt`. If a store is missing, add its
  city or postal code to `extra_seeds`.
- `bestscrap.bat` just launches `bestscrap.ps1`; batch can't parse JSON.
- Sound on Linux uses the first of paplay, aplay, play, ffplay or mpv it finds,
  and falls back to the terminal bell. WSL and Git Bash play through Windows.
