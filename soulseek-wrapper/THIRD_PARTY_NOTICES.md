# Third Party Notices

This file documents third-party components used in `soulseek-wrapper`.

---

## Soulseek.NET

- **Project:** Soulseek.NET
- **Author:** JP Dillingham
- **License:** GPL-3.0-only
- **Source:** https://github.com/jpdillingham/Soulseek.NET
- **Version:** 10.0.2

A .NET Standard client library for the Soulseek peer-to-peer network. Provides
`SoulseekClient` with `ConnectAsync`, `SearchAsync`, `DownloadAsync`,
`BrowseAsync`, transfer state events and options (`SoulseekClientOptions`,
`SearchOptions`, `TransferOptions`).

```
Copyright (c) JP Dillingham
SPDX-License-Identifier: GPL-3.0-only
```

---

## SeekerAndroid (modifications to Soulseek.NET)

- **Project:** SeekerAndroid
- **Author:** Jack Bonadies (nicholasgcoles)
- **License:** GPL-3.0-only + Additional Terms (Section 7 of GPLv3)
- **Source:** https://github.com/nicholasgcoles/Seeker

The copy of Soulseek.NET bundled here is **modified** by the SeekerAndroid
project. The following modifications are present and are critical for correct
operation on Android:

1. **Latin-1 (ISO-8859-1) encoding fallback** — filenames and folder names may
   be decoded as Latin-1 instead of UTF-8, which is essential for correct
   handling of Cyrillic and other non-ASCII characters in shared file names.
   (`File.IsLatin1Decoded`, `File.IsDirectoryLatin1Decoded`,
   `Directory.DecodedViaLatin1`.)
2. **Address resolver support** — `SoulseekClientOptions` accepts an
   `addressResolver` delegate (`Func<string, Task<IPAddress>>`) so the host
   application can resolve `server.slsknet.org` with IPv4-only forced lookups
   and a hardcoded fallback IP, avoiding ~20% DNS timeout failures observed on
   Android where no AAAA record exists.
3. **Listener state** — `SoulseekClient.GetListeningState()` reports whether the
   listener is actually running (useful because binding can fail with
   "Address already in use").
4. **Transfer lookup methods** — additional states
   (`UserOffline`, `CannotConnect`, `FallenFromQueue`, `SizeMismatch`) and
   `IsTransferInDownloads(username, filename)` to detect tracked transfers that
   must be cancelled before retry.

```
Copyright (c) 2021-2026 Jack Bonadies
This program is distributed with Additional Terms pursuant to Section 7
of the GPLv3. See the LICENSE file for the complete terms and conditions.
SPDX-License-Identifier: GPL-3.0-only
```

---

## Microsoft.CSharp

- **License:** MIT
- **Used by:** Soulseek.NET (dynamic dispatch in protocol messaging).

## System.Memory

- **License:** MIT
- **Used by:** Soulseek.NET (`Memory<T>`, `Span<T>` support).

## System.Text.Json

- **License:** MIT
- **Used by:** soulseek-wrapper bridge for JSON (de)serialization of DTOs
  between C# and Kotlin/Flutter.

---

## License Summary

The `soulseek-wrapper` project and the bundled (modified) Soulseek.NET are
licensed under **GPL-3.0-only**. See `LICENSE` for the full text.
