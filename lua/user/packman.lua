local Job = require"user.job"
local Deque = require("user.deque").Deque

local function gen_helptags(pack)
    vim.api.nvim_command("silent! helptags "..vim.fn.fnameescape(pack.install_path).."/doc")
end

local function git_head_hash(pack)
    return vim.fn.system([[git -C "]]..pack.install_path..[[" rev-parse HEAD]])
end

local function packadd(pack)
    vim.api.nvim_command("packadd! "..vim.fn.fnameescape(pack.packadd_path))
end

local function chdir_do_fun(dir, fun)
    local cwd = vim.loop.cwd()
    vim.loop.chdir(dir)
    pcall(fun)
    vim.loop.chdir(cwd)
end

local function post_install(pack)
    gen_helptags(pack)
    if pack.install then
        chdir_do_fun(pack.install_path, pack.install)
    end
end

local function post_update(pack)
    local hash = git_head_hash(pack)
    if pack.hash and pack.hash ~= hash then
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
        path = (args.path and vim.fn.resolve(vim.fn.fnamemodify(args.path, ":p"))) or vim.fn.stdpath("data").."/site/pack/user/",

        packs = {},

        config_queue = Deque:new(),

        jobs = {},

	errs = {},

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

    local job = Job:new({
        command = 'git',
        args = { 'clone', '--quiet', '--recurse-submodules', '--shallow-submodules',
            pack.repo, pack.install_path},
        on_exit = function(j, return_val)
            if return_val ~= 0 then
                table.insert(self.errs, j:stderr_result())
            else
                post_install(pack)
                packadd(pack)
            end
        end,
    })
    job:start()
    table.insert(self.jobs, job)
end

function PackMan:update(pack)
    pack.hash = git_head_hash(pack)

    local job = Job:new({
        command = 'git',
        args = { '-C', pack.install_path, 'pull', '--quiet', '--recurse-submodules', '--update-shallow'},
        on_exit = function(j, return_val)
            if return_val ~= 0 then
                table.insert(self.errs, j:stderr_result())
            else
                post_update(pack)
            end
        end,
    })
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
    for _, err in ipairs(self.errs) do
        vim.notify(table.concat(err,"\n"), vim.log.levels.ERROR)
    end
    self.errs = {}
end

function PackMan:flush_config_queue()
    while self.config_queue:len() > 0 do
        local config = self.config_queue:pop_front()
        config()
    end
end

function PackMan:update_all()
    for _, pack in pairs(self.packs) do
        self:update(pack)
    end
end

return { PackMan = PackMan }
