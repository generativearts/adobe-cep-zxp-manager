# Third-Party Notices

## ZXPSignCmd

This project uses Adobe's ZXPSignCmd to sign and verify CEP packages. The
executable is not included in this repository. Obtain it from Adobe's
[CEP-Resources repository](https://github.com/Adobe-CEP/CEP-Resources/tree/master/ZXPSignCMD)
and place the Windows x64 executable at `zxp_tools\ZXPSignCmd.exe`, or select
its location in **Projects & Settings**.

Adobe links the
[CEP SDK license agreement](https://github.com/Adobe-CEP/CEP-Resources/blob/master/License/GenSDK_IHC-en_US-20120323_1224.pdf)
from CEP-Resources. That agreement defines the SDK to include tools, grants
use for internal development of applications designed to work with Adobe
products, and restricts unbundling or repackaging SDK components for
distribution. Review and accept the applicable Adobe terms when obtaining
the tool. This project's MIT license does not apply to ZXPSignCmd or grant
permission to redistribute it.

The local executable used during development was byte-for-byte matched to
Adobe CEP-Resources `ZXPSignCMD/4.1.3/x64/ZXPSignCmd.exe` using its Git blob
SHA-1 (`f5df2ed805e04a4d3c6adc722f602d4df6c762f7`). That local file is
unsigned by Authenticode and is kept out of Git.

## Other bundled components

The ZXPSignCmd executable contains third-party components, including OpenSSL
and Info-ZIP code. Their notices and terms belong to those components and are
not covered by this project's MIT license. Since the executable is not
distributed here, obtain it and review the notices from Adobe's official
distribution.
