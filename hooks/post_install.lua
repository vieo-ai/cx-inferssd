--- Performs prebuilt archive extraction (Windows/macOS) or hermetic source build (Linux)
--- Documentation: https://mise.jdx.dev/tool-plugin-development.html#postinstall-hook
--- @param ctx {rootPath: string, runtimeVersion: string, sdkInfo: table} Context
function PLUGIN:PostInstall(ctx)
    local sdkInfo = ctx.sdkInfo[PLUGIN.name]
    local target_dir = sdkInfo.path

    local raw_version = (sdkInfo and sdkInfo.version) or ctx.runtimeVersion or ctx.version or "latest"
    local raw_tag = tostring(raw_version)
    local version = raw_tag:gsub("^v", "")
    local release_tag = (raw_tag == "latest" or raw_tag == "") and "latest" or ("v" .. version)

    local os_type = RUNTIME.osType:lower()
    local arch_type = (RUNTIME.archType or ""):lower()
    local is_win = (os_type == "windows")
    local is_mac = (os_type == "darwin")
    local is_linux = (os_type == "linux")

    local function join_path(a, b)
        if not a or a == "" then return b end
        if not b or b == "" then return a end
        local sep = is_win and "\\" or "/"
        local clean_a = a:gsub("[\\/]+$", "")
        local clean_b = b:gsub("^[\\/]+", "")
        return clean_a .. sep .. clean_b
    end

    local function test_path(p)
        if not p or p == "" then return false end
        local f = io.open(p, "r")
        if f ~= nil then
            f:close()
            return true
        end
        return false
    end

    local function write_clause_log(msg, level)
        io.stderr:write(string.format("[inferssd][%s] %s\n", level or "INFO", msg))
    end

    local function run_cmd(cmd)
        local code = os.execute(cmd)
        if code ~= 0 and code ~= true then
            error(string.format("[inferssd] Command failed with exit code %s: %s", tostring(code), cmd))
        end
    end

    local function capture_cmd(cmd)
        local full_cmd = cmd
        if is_win then
            full_cmd = '%COMSPEC% /d /s /c "' .. cmd .. '"'
        end
        local p = io.popen(full_cmd)
        if not p then return "" end
        local out = p:read("*a")
        p:close()
        return out or ""
    end

    local exe_ext = is_win and ".exe" or ""
    local bin_dir = join_path(target_dir, "bin")
    local inferssd_bin = join_path(bin_dir, "inferssd" .. exe_ext)
    local server_bin = join_path(bin_dir, "inferssd-server" .. exe_ext)
    local resources_json = join_path(target_dir, "engine-resources.json")

    -- Fast-path idempotency check
    if test_path(inferssd_bin) and test_path(server_bin) and test_path(resources_json) then
        return
    end

    local clause_temp_dir = os.getenv("CLAUSE_TEMP_DIR") or (is_win and (os.getenv("TEMP") or target_dir) or "/tmp")
    local dirs_to_provision = { target_dir, bin_dir, clause_temp_dir }
    for _, d in ipairs(dirs_to_provision) do
        if not test_path(d) then
            if is_win then
                os.execute('if not exist "' .. d .. '" mkdir "' .. d .. '" >nul 2>&1')
            else
                os.execute('mkdir -p "' .. d .. '"')
            end
        end
    end

    local base_release_url = (release_tag == "latest")
        and "https://github.com/wici-ai/inferssd/releases/latest/download"
        or string.format("https://github.com/wici-ai/inferssd/releases/download/%s", release_tag)

    -- ==============================================================================
    -- 1. WINDOWS X64: PREBUILT ARCHIVE VIA latest-windows.json
    -- ==============================================================================
    if is_win then
        if arch_type ~= "amd64" and arch_type ~= "x86_64" then
            error("[inferssd] Windows x64 (amd64) is required.")
        end

        local listing_url = base_release_url .. "/latest-windows.json"
        local stage_dir = join_path(clause_temp_dir, "inferssd-win-" .. tostring(os.time()))
        write_clause_log("Fetching Windows release manifest (" .. listing_url .. ")...", "INFO")

        local ps_script = string.format([[
            $ErrorActionPreference = 'Stop'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $stage = '%s'
            $target = '%s'
            New-Item -ItemType Directory -Force -Path $stage, $target | Out-Null
            try {
                $listing = Join-Path $stage 'latest-windows.json'
                Invoke-WebRequest -UseBasicParsing -Uri '%s' -OutFile $listing
                $pkg = Get-Content -LiteralPath $listing -Raw | ConvertFrom-Json
                if ($pkg.schema -ne 'inferssd-package 1' -or $pkg.platform -ne 'windows-x64') {
                    throw 'Unsupported Windows package manifest.'
                }
                $archive = Join-Path $stage $pkg.file
                Write-Host ("[inferssd][INFO] Downloading " + $pkg.file + " (" + [math]::Ceiling($pkg.size / 1000000) + " MB)...")
                Invoke-WebRequest -UseBasicParsing -Uri $pkg.url -OutFile $archive
                $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actual -ne $pkg.sha256.ToLowerInvariant()) {
                    throw 'SHA256 checksum mismatch on downloaded Windows archive.'
                }
                $unpack = Join-Path $stage 'unpack'
                [System.IO.Compression.ZipFile]::ExtractToDirectory($archive, $unpack)
                $inner = Join-Path $unpack $pkg.name
                if (-not (Test-Path -LiteralPath $inner)) {
                    $inner = (Get-ChildItem -LiteralPath $unpack -Directory | Select-Object -First 1).FullName
                }
                Get-ChildItem -LiteralPath $inner -Force | ForEach-Object {
                    $dest = Join-Path $target $_.Name
                    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
                    Move-Item -LiteralPath $_.FullName -Destination $dest
                }
            } finally {
                if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
            }
        ]], stage_dir, target_dir, listing_url)

        local ps_file = join_path(clause_temp_dir, "clause-inferssd-install-" .. tostring(os.time()) .. ".ps1")
        local f_ps = io.open(ps_file, "w")
        if not f_ps then error("[inferssd] Unable to write transient PowerShell installer.") end
        f_ps:write(ps_script)
        f_ps:close()

        local ok, err = pcall(function()
            run_cmd(string.format('powershell -NoProfile -ExecutionPolicy Bypass -File "%s"', ps_file))
        end)
        if test_path(ps_file) then os.remove(ps_file) end
        if not ok then error(err) end

        if not test_path(inferssd_bin) or not test_path(resources_json) then
            error("[inferssd] Extracted Windows package is missing bin/inferssd.exe or engine-resources.json.")
        end

        write_clause_log("InferSSD Windows x64 prebuilt engine provisioned.", "INFO")
        return
    end

    -- ==============================================================================
    -- 2. MACOS ARM64: PREBUILT ARCHIVE VIA latest-macos.json
    -- ==============================================================================
    if is_mac then
        if arch_type ~= "arm64" and arch_type ~= "aarch64" then
            error("[inferssd] Prebuilt macOS releases require Apple Silicon (arm64).")
        end

        local listing_url = base_release_url .. "/latest-macos.json"
        local stage_dir = join_path(clause_temp_dir, "inferssd-mac-" .. tostring(os.time()))
        write_clause_log("Fetching macOS release manifest (" .. listing_url .. ")...", "INFO")

        local sh_script = string.format([[
            set -euo pipefail
            stage=%q
            target=%q
            mkdir -p "$stage" "$target"
            trap 'rm -rf "$stage"' EXIT
            curl -fsSL --retry 3 -o "$stage/latest-macos.json" %q
            schema=$(plutil -extract schema raw -o - "$stage/latest-macos.json")
            [ "$schema" = "inferssd-package 1" ] || { echo "Unsupported macOS package manifest" >&2; exit 1; }
            pkg_name=$(plutil -extract name raw -o - "$stage/latest-macos.json")
            pkg_url=$(plutil -extract url raw -o - "$stage/latest-macos.json")
            pkg_sha=$(plutil -extract sha256 raw -o - "$stage/latest-macos.json" | tr '[:upper:]' '[:lower:]')
            curl -fL --retry 3 -o "$stage/package.tar.gz" "$pkg_url"
            actual=$(shasum -a 256 "$stage/package.tar.gz" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
            [ "$actual" = "$pkg_sha" ] || { echo "SHA256 checksum mismatch on macOS archive" >&2; exit 1; }
            tar -xzf "$stage/package.tar.gz" -C "$stage"
            cp -Rf "$stage/$pkg_name"/. "$target"/
        ]], stage_dir, target_dir, listing_url)

        run_cmd(string.format("bash -c %q", sh_script))

        if not test_path(inferssd_bin) or not test_path(resources_json) then
            error("[inferssd] Extracted macOS package is missing bin/inferssd or engine-resources.json.")
        end

        write_clause_log("InferSSD macOS arm64 prebuilt engine provisioned.", "INFO")
        return
    end

    -- ==============================================================================
    -- 3. LINUX: HERMETIC SOURCE BUILD (CUDA / VULKAN / CPU)
    -- ==============================================================================
    if not is_linux then
        error("[inferssd] Unsupported operating system: " .. os_type)
    end

    -- Probe uv (matching mise-comfyui conventions)
    local function probe_uv()
        local clause_bin = os.getenv("CLAUSE_BIN_DIR") or ""
        local direct_uv = clause_bin ~= "" and join_path(clause_bin, "uv") or ""
        if direct_uv ~= "" and test_path(direct_uv) then return direct_uv end

        local cmd_probe = capture_cmd("command -v uv 2>/dev/null")
        local found_uv = cmd_probe:match("^[^\r\n]+")
        if found_uv and found_uv ~= "" and test_path(found_uv) then return found_uv end

        local clause_home = os.getenv("CLAUSE_HOME") or ""
        local user_home = os.getenv("HOME") or ""
        local mise_shim_rel = ".local/share/mise/shims/uv"

        local mise_shims = clause_home ~= "" and join_path(clause_home, mise_shim_rel) or ""
        if mise_shims ~= "" and test_path(mise_shims) then return mise_shims end

        local alt_shims = join_path(user_home, mise_shim_rel)
        if test_path(alt_shims) then return alt_shims end

        return nil
    end

    local uv_exe = probe_uv()
    if not uv_exe then
        write_clause_log("uv not found on host; provisioning uv via Mise...", "INFO")
        os.execute("mise use -g uv@latest")
        uv_exe = probe_uv()
    end
    if not uv_exe then
        error("[inferssd] Missing prerequisite: uv")
    end

    local venv_dir = join_path(target_dir, "venv")
    local source_dir = join_path(target_dir, "src")
    local private_py_dir = join_path(target_dir, "python")
    local clause_cache_dir = os.getenv("CLAUSE_CACHE_DIR") or join_path(target_dir, "cache")
    local uv_cache_dir = join_path(clause_cache_dir, "uv")

    for _, d in ipairs({ private_py_dir, clause_cache_dir, uv_cache_dir }) do
        os.execute('mkdir -p "' .. d .. '"')
    end

    local function run_uv(subcommand)
        run_cmd(string.format('UV_CACHE_DIR="%s" UV_PYTHON_INSTALL_DIR="%s" "%s" %s', uv_cache_dir, private_py_dir, uv_exe, subcommand))
    end

    local function capture_uv(subcommand)
        return capture_cmd(string.format('UV_CACHE_DIR="%s" UV_PYTHON_INSTALL_DIR="%s" "%s" %s', uv_cache_dir, private_py_dir, uv_exe, subcommand))
    end

    write_clause_log("Provisioning hermetic Python 3.12 for Linux source build...", "INFO")
    run_uv("python install --no-bin --no-registry 3.12")

    local base_python = ""
    for line in capture_uv("python find 3.12"):gmatch("[^\r\n]+") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" and test_path(trimmed) then
            base_python = trimmed
            break
        end
    end
    if base_python == "" then
        error("[inferssd] Unable to locate provisioned Python 3.12 in " .. private_py_dir)
    end

    local venv_python = join_path(venv_dir, "bin/python")
    if not test_path(venv_python) then
        run_uv(string.format('venv "%s" --python "%s"', venv_dir, base_python))
    end

    if not test_path(join_path(source_dir, "CMakeLists.txt")) then
        os.execute(string.format('rm -rf "%s"', source_dir))
        local clone_ref = (release_tag ~= "latest") and release_tag or "v0.1.4"
        write_clause_log("Cloning InferSSD source (" .. clone_ref .. ")...", "INFO")
        run_cmd(string.format('git clone --filter=blob:none --single-branch --branch "%s" https://github.com/wici-ai/inferssd.git "%s"', clone_ref, source_dir))
    end

    write_clause_log("Installing CMake, Ninja, and InferSSD Python framework...", "INFO")
    run_uv(string.format('pip install --python "%s" "cmake>=3.24,<5" ninja "%s/framework[hf]"', venv_python, source_dir))

    local backend = capture_cmd(string.format('PYTHONPATH="%s/framework/src" "%s" -m inferssd.machine.backend', source_dir, venv_python)):gsub("[\r\n]+", "")
    local preset = "linux-cpu"
    local vulkan_flag = ""
    local cuda_env = ""
    local build_targets = "inferssd-server inferssd-cpuprobe inferssd-ssdprobe"

    if backend == "CUDA" then
        preset = "linux-cuda"
        build_targets = "inferssd-server inferssd-cpuprobe inferssd-ssdprobe inferssd-memprobe"
        local nvcc_path = os.getenv("CUDACXX") or capture_cmd("command -v nvcc 2>/dev/null"):gsub("[\r\n]+", "")
        if nvcc_path == "" and test_path("/usr/local/cuda/bin/nvcc") then
            nvcc_path = "/usr/local/cuda/bin/nvcc"
        end
        if nvcc_path == "" then
            error("[inferssd] NVIDIA GPU detected, but nvcc was not found. Install CUDA toolkit or set CUDACXX.")
        end
        cuda_env = string.format('CUDACXX="%s" ', nvcc_path)
    elseif backend == "Vulkan" then
        if os.execute("command -v glslc >/dev/null 2>&1") == 0 then
            vulkan_flag = " -DGGML_VULKAN=ON"
        else
            write_clause_log("AMD/Intel GPU detected, but glslc (Vulkan SDK) not found; building CPU fallback.", "WARN")
        end
    end

    local jobs = os.getenv("INFERSSD_JOBS") or "4"
    local build_dir = join_path(source_dir, "build-" .. preset)
    local venv_bin = join_path(venv_dir, "bin")

    write_clause_log(string.format("Compiling InferSSD native engine (%s%s)...", preset, vulkan_flag), "INFO")
    run_cmd(string.format(
        'cd "%s" && %sPATH="%s:$PATH" cmake --preset "%s"%s && %sPATH="%s:$PATH" cmake --build "%s" --parallel "%s" --target %s',
        source_dir, cuda_env, venv_bin, preset, vulkan_flag, cuda_env, venv_bin, build_dir, jobs, build_targets
    ))

    run_cmd(string.format('"%s" "%s/scripts/engine-resources.py" --build "%s" --output "%s"', venv_python, source_dir, build_dir, resources_json))

    -- Create POSIX wrapper in target_dir/bin/inferssd
    local f_sh = io.open(inferssd_bin, "w")
    if f_sh then
        f_sh:write("#!/usr/bin/env sh\n")
        f_sh:write("DIR=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"\n")
        f_sh:write("export INFERSSD_HOME=\"${INFERSSD_HOME:-$DIR}\"\n")
        f_sh:write("export INFERSSD_RESOURCES=\"${INFERSSD_RESOURCES:-$DIR/engine-resources.json}\"\n")
        f_sh:write("exec \"$DIR/venv/bin/inferssd\" \"$@\"\n")
        f_sh:close()
    end
    os.execute('chmod +x "' .. inferssd_bin .. '"')

    -- Symlink native server binary into target_dir/bin/inferssd-server
    local built_server = join_path(build_dir, "bin/inferssd-server")
    if test_path(built_server) then
        os.execute(string.format('ln -sf "%s" "%s"', built_server, server_bin))
    end

    write_clause_log("InferSSD Linux engine successfully built and provisioned.", "INFO")
end