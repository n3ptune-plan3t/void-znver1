Drop a file named `<package>.conf` here (normal /etc/xbps.d syntax,
e.g. `repository=https://example.com/some-repo`) if that package needs
build-time dependencies from somewhere other than stock Void - for
example a custom package that needs a newer compiler/toolchain version
than Void's official repo currently carries. It gets copied into the
build's masterdir automatically before that package builds.
