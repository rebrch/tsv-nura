# Where the EDL (firehose) files come from

> **Not in git.** These are proprietary Qualcomm/Lenovo files and are git-ignored, so they are never pushed.
> To get them, run `flash/fetch-firehose.sh`. It downloads the archive below, verifies its sha256 and the sha256 of both
> extracted files (`flash/SHA256SUMS`), and puts them here. If you already have the archive, pass its path to the script.
> Extracting needs `bsdtar` (built into macOS; `libarchive-tools` on Debian/Ubuntu) or `7z`.

`prog_emmc_firehose_8953_ddr.mbn` is Qualcomm's signed MSM8953 firehose programmer for the ThinkSmart View. `edl` uploads it
to the SoC's emergency download mode (Sahara/Firehose) so the eMMC can be read and written. `rawprogram0.xml` is the
matching stock partition layout. **These are the exact files used to back up and flash the reference unit.**

| File | sha256 | Date inside archive |
|---|---|---|
| `prog_emmc_firehose_8953_ddr.mbn` | `04e7f2f9495a2e7c70848a3587ee6336c9ab58e27f3153c1513a83d79133f5c6` | 2019-10-11 |
| `rawprogram0.xml` | `e2cba424ab7e398c8628567a4f3d85be85c91cf28ccb88d4267a047c0d2ba77d` | 2019-10-11 |

## Source

- **Archive:** `CD-18781Y-firehose-rawprogram.7z` (sha256 `caed20e5451ce7682085789ace1cdc19c0fbf487027ec01c54a03090c748f315`).
- **Downloaded from:** <https://s3.wasabisys.com/filestash-buk/lenovo-thinksmart-view/CD-18781Y-firehose-rawprogram.7z>
- **Linked from:** the XDA thread "CD-18781Y Lenovo ThinkSmart View bootloader / firmware / Zoom-Teams conversion / normal Android":
  <https://xdaforums.com/t/cd-18781y-lenovo-thinksmart-view-bootloader-firmware-zoom-teams-conversion-normal-android.4426029/>

## Related: the stock firmware package

The same host serves Lenovo's full stock firmware: `CD-18781Y.200628.084.zip` (1.29 GB, sha256
`4356762c02e6d74ee4bb0ef83c9e4dba910453bb5f14fa3ac9ed321ec4bfa686`) from
<https://s3.wasabisys.com/filestash-buk/lenovo-thinksmart-view/CD-18781Y.200628.084.zip>.

Its `image/prog_emmc_firehose_8953_ddr.mbn` is a **different build** (sha256 `82de7384…0887`). It was not used or tested
here; this repo's flashing was done only with the loader above.

These are vendor binaries (Qualcomm/Lenovo) and are not redistributed by this repo. To use a different copy, put it here and
update `flash/SHA256SUMS`. That copy is untested.
