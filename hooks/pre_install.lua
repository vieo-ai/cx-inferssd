--- Prepares the download package before installation
--- Documentation: https://mise.jdx.dev/tool-plugin-development.html#preinstall-hook
--- @param ctx {version: string} Context
function PLUGIN:PreInstall(ctx)
    local raw_version = ctx.version or "latest"
    local version = tostring(raw_version):gsub("^v", "")

    -- Precompiled release archives on Windows/macOS are resolved via latest-<os>.json,
    -- and Linux builds hermetically from source inside PostInstall.
    return {
        version = version
    }
end