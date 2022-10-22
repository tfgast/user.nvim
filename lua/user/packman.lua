local Job = require"user.job"
local Deque = require("user.deque").Deque

local function gen_helptags(pack)
    vim.cmd(("silent! helptags %s/doc"):format(vim.fn.fnameescape(pack.install_path)))
end

local function git_head_hash(pack)
    return vim.fn.system { "git", "-C", pack.install_path, "rev-parse", "HEAD" }
end

local function packadd(pack)
    vim.cmd(("packadd %s"):format(vim.fn.fnameescape(pack.packadd_path)))
end

local function chdir_do_fun(dir, fun)
    local cwd = vim.loop.cwd()
    vim.loop.chdir(dir)
    local succeeded, res = pcall(fun)
    if not succeeded then
        vim.notify(res, vim.log.levels.ERROR)
    end
    vim.loop.chdir(cwd)
end

local function post_install(pack)
    vim.notify("installed "..pack.name, vim.log.levels.INFO)
    gen_helptags(pack)
    if pack.install then
        chdir_do_fun(pack.install_path, pack.install)
    end
end

local function post_update(pack)
    local hash = git_head_hash(pack)
    if pack.hash and pack.hash ~= hash then
        local msg = vim.fn.system([[git -C "]]..pack.install_path..[[" log --pretty=format:"%s" ORIG_HEAD..]])
        vim.notify("updated "..pack.name.."\n"..msg, vim.log.levels.INFO)
        gen_helptags(pack)
        if pack.update then
            chdir_do_fun(pack.install_path, pack.update)
        end
        pack.hash = hash
    end
end

local PackMan = {}

function PackMan:new(args)
    args = args or {}
    local packman = {
        path = (args.path and vim.fn.resolve(vim.fn.fnamemodify(args.path, ":p")))
            or (vim.fn.stdpath "data").."/site/pack/user/",

        packs = {},

        config_queue = Deque:new(),

        jobs = {},

    }
    self.__index = self
    setmetatable(packman, self)
    return packman
end

function PackMan:install(pack)
    if vim.fn.isdirectory(pack.install_path) == 1 then
        packadd(pack)
        return
    end
    vim.notify("installing "..pack.name, vim.log.levels.INFO)

    local job = Job:new({
        command = 'git',
        args = { 'clone', '--quiet', '--recurse-submodules', '--shallow-submodules',
            pack.repo, pack.install_path},
        on_exit = vim.schedule_wrap(function(j, return_val)
            if return_val ~= 0 then
                vim.notify(table.concat(j:stderr_result(),"\n"), vim.log.levels.ERROR)
            else
                post_install(pack)
                packadd(pack)
            end
        end),
    })
    job:start()
    table.insert(self.jobs, job)
end

function PackMan:update(pack)
    pack.hash = git_head_hash(pack)

    local job = Job:new({
        command = 'git',
        args = { '-C', pack.install_path, 'pull', '--recurse-submodules', '--update-shallow'},
        on_exit = vim.schedule_wrap(function(j, return_val)
            if return_val ~= 0 then
                local err_msg = table.concat(j:stderr_result(),"\n")
                vim.notify("updating "..pack.name.."\n"..err_msg, vim.log.levels.ERROR)
            else
                post_update(pack)
            end
        end),
    })
    job:start()
    table.insert(self.jobs, job)
end

function PackMan:request(pack)
    if self.packs[pack.name] then
        return self.packs[pack.name]
    end
    self.packs[pack.name] = pack

    if pack.init then pack.init() end

    local install_path = pack.name

    local packadd_path = install_path
    if pack.subdir then packadd_path = packadd_path.."/"..pack.subdir end

    pack.packadd_path = packadd_path
    pack.install_path = self.path.."/opt/"..install_path

    self:install(pack)
    if pack.config then
        self.config_queue:push_back(pack.config)
    end

    return pack
end

function PackMan:flush_jobs()
    Job.join(unpack(self.jobs))
end

function PackMan:flush_config_queue()
    while self.config_queue:len() > 0 do
        local config = self.config_queue:pop_front()
        local succeeded, res = pcall(config)
        if not succeeded then
            vim.notify(res, vim.log.levels.ERROR)
        end
    end
end

function PackMan:update_all()
    for _, pack in pairs(self.packs) do
        self:update(pack)
    end
end

function PackMan:clean()
    local keep = {}
    for _, pack in pairs(self.packs) do
        keep[vim.fn.resolve(pack.install_path)] = true
    end

    for place in vim.fn.glob(vim.fn.stdpath "data" .. "/site/pack/user/opt/*/*/"):gmatch "[^\n]+" do
        place = vim.fn.resolve(place)
        if not keep[place] then
            if vim.fn.confirm("Delete folder " .. place) == 1 then
                vim.fn.delete(place, "rf")
            end
        end
    end

    for place in vim.fn.glob(vim.fn.stdpath "data" .. "/site/pack/user/opt/*"):gmatch "[^\n]+" do
        place = vim.fn.resolve(place)
        local empty = true
        for file in vim.fn.glob(place .. "/*/**"):gmatch "[^\n]+" do
            if vim.fn.isdirectory(file) == 0 then
                empty = false
                break
            end
        end

        if empty then
            if vim.fn.confirm("Delete folder " .. place) == 1 then
                vim.fn.delete(place, "rf")
            end
        end
    end
end

return { PackMan = PackMan }
