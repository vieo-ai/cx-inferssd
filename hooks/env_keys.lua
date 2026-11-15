--- Exports environment variables and path adjustments for Mise
--- Documentation: https://mise.jdx.dev/tool-plugin-development.html#envkeys-hook
--- @param ctx {path: string, version: string} Context
function PLUGIN:EnvKeys(ctx)
    local target_dir = ctx.path
    local os_type = RUNTIME.osType:lower()
    local is_win = (os_type == "windows")

    local function join_path(a, b)
        local sep = is_win and "\\" or "/"
        local clean_a = a:gsub("[\\/]+$", "")
        local clean_b = b:gsub("^[\\/]+", "")
        return clean_a .. sep .. clean_b
    end

    local bin_dir = join_path(target_dir, "bin")
    local resources_path = join_path(target_dir, "engine-resources.json")

    -- Confine downloaded model weights inside CLAUSE_ML_HUB_DIR when available
    local ml_hub_dir = os.getenv("CLAUSE_ML_HUB_DIR") or ""
    local inferssd_home = (ml_hub_dir ~= "") and join_path(ml_hub_dir, "inferssd") or target_dir

    return {
        {
            key = "PATH",
            value = bin_dir
        },
        {
            key = "INFERSSD_HOME",
            value = inferssd_home
        },
        {
            key = "INFERSSD_RESOURCES",
            value = resources_path
        }
    }
end