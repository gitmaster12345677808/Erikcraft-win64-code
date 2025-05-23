--Minetest
--Copyright (C) 2018-20 rubenwardy
--
--This program is free software; you can redistribute it and/or modify
--it under the terms of the GNU Lesser General Public License as published by
--the Free Software Foundation; either version 2.1 of the License, or
--(at your option) any later version.
--
--This program is distributed in the hope that it will be useful,
--but WITHOUT ANY WARRANTY; without even the implied warranty of
--MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--GNU Lesser General Public License for more details.
--
--You should have received a copy of the GNU Lesser General Public License along
--with this program; if not, write to the Free Software Foundation, Inc.,
--51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

if not core.get_http_api then
	function create_store_dlg()
		return messagebox("store",
				fgettext("ContentDB is not available when Minetest was compiled without cURL"))
	end
	return
end

local store = {
	loading = false,
	load_ok = false,
	load_error = false,

	-- Unordered preserves the original order of the ContentDB API,
	-- before the package list is ordered based on installed state.
	packages = {},
	packages_full = {},
	packages_full_unordered = {},
	aliases = {},
}

local http = core.get_http_api()

-- Screenshot
local screenshot_dir = core.get_cache_path() .. DIR_DELIM .. "cdb"
assert(core.create_dir(screenshot_dir))
local screenshot_downloading = {}
local screenshot_downloaded = {}

-- Filter
local search_string = ""
local cur_page = 1
local num_per_page = 5
local filter_type = 1
local filter_types_titles = {
	fgettext("All packages"),
	fgettext("Games"),
	fgettext("Mods"),
	fgettext("Texture packs"),
}

-- Automatic package installation
local auto_install_spec = nil

local number_downloading = 0
local download_queue = {}

local filter_types_type = {
	nil,
	"game",
	"mod",
	"txp",
}

local REASON_NEW = "new"
local REASON_UPDATE = "update"
local REASON_DEPENDENCY = "dependency"


local function get_download_url(package, reason)
	local base_url = core.settings:get("contentdb_url")
	local ret = base_url .. ("/packages/%s/releases/%d/download/"):format(
		package.url_part, package.release)
	if reason then
		ret = ret .. "?reason=" .. reason
	end
	return ret
end


local function download_and_extract(param)
	local package = param.package

	local filename = core.get_temp_path(true)
	if filename == "" or not core.download_file(param.url, filename) then
		core.log("error", "Downloading " .. dump(param.url) .. " failed")
		return {
			msg = fgettext_ne("Failed to download \"$1\"", package.title)
		}
	end

	local tempfolder = core.get_temp_path()
	if tempfolder ~= "" then
		tempfolder = tempfolder .. DIR_DELIM .. "MT_" .. math.random(1, 1024000)
		if not core.extract_zip(filename, tempfolder) then
			tempfolder = nil
		end
	else
		tempfolder = nil
	end
	os.remove(filename)
	if not tempfolder then
		return {
			msg = fgettext_ne("Failed to extract \"$1\" (unsupported file type or broken archive)", package.title),
		}
	end

	return {
		path = tempfolder
	}
end

local function start_install(package, reason)
	local params = {
		package = package,
		url = get_download_url(package, reason),
	}

	number_downloading = number_downloading + 1

	local function callback(result)
		if result.msg then
			gamedata.errormessage = result.msg
		else
			local path, msg = pkgmgr.install_dir(package.type, result.path, package.name, package.path)
			core.delete_dir(result.path)
			if not path then
				gamedata.errormessage = fgettext_ne("Error installing \"$1\": $2", package.title, msg)
			else
				core.log("action", "Installed package to " .. path)

				local conf_path
				local name_is_title = false
				if package.type == "mod" then
					local actual_type = pkgmgr.get_folder_type(path)
					if actual_type.type == "modpack" then
						conf_path = path .. DIR_DELIM .. "modpack.conf"
					else
						conf_path = path .. DIR_DELIM .. "mod.conf"
					end
				elseif package.type == "game" then
					conf_path = path .. DIR_DELIM .. "game.conf"
					name_is_title = true
				elseif package.type == "txp" then
					conf_path = path .. DIR_DELIM .. "texture_pack.conf"
				end

				if conf_path then
					local conf = Settings(conf_path)
					conf:set("title", package.title)
					if not name_is_title then
						conf:set("name", package.name)
					end
					if not conf:get("description") then
						conf:set("description", package.short_description)
					end
					conf:set("author",     package.author)
					conf:set("release",    package.release)
					conf:write()
				end
			end
		end

		package.downloading = false

		number_downloading = number_downloading - 1

		local next = download_queue[1]
		if next then
			table.remove(download_queue, 1)

			start_install(next.package, next.reason)
		end

		ui.update()
	end

	package.queued = false
	package.downloading = true

	if not core.handle_async(download_and_extract, params, callback) then
		core.log("error", "ERROR: async event failed")
		gamedata.errormessage = fgettext_ne("Failed to download $1", package.name)
		return
	end
end

local function queue_download(package, reason)
	if package.queued or package.downloading then
		return
	end

	local max_concurrent_downloads = tonumber(core.settings:get("contentdb_max_concurrent_downloads"))
	if number_downloading < math.max(max_concurrent_downloads, 1) then
		start_install(package, reason)
	else
		table.insert(download_queue, { package = package, reason = reason })
		package.queued = true
	end
end

local function get_raw_dependencies(package)
	if package.type ~= "mod" then
		return {}
	end
	if package.raw_deps then
		return package.raw_deps
	end

	local url_fmt = "/api/packages/%s/dependencies/?only_hard=1&protocol_version=%s&engine_version=%s"
	local version = core.get_version()
	local base_url = core.settings:get("contentdb_url")
	local url = base_url .. url_fmt:format(package.url_part, core.get_max_supp_proto(), core.urlencode(version.string))

	local response = http.fetch_sync({ url = url })
	if not response.succeeded then
		return
	end

	local data = core.parse_json(response.data) or {}

	local content_lookup = {}
	for _, pkg in pairs(store.packages_full) do
		content_lookup[pkg.id] = pkg
	end

	for id, raw_deps in pairs(data) do
		local package2 = content_lookup[id:lower()]
		if package2 and not package2.raw_deps then
			package2.raw_deps = raw_deps

			for _, dep in pairs(raw_deps) do
				local packages = {}
				for i=1, #dep.packages do
					packages[#packages + 1] = content_lookup[dep.packages[i]:lower()]
				end
				dep.packages = packages
			end
		end
	end

	return package.raw_deps
end

local function has_hard_deps(raw_deps)
	for i=1, #raw_deps do
		if not raw_deps[i].is_optional then
			return true
		end
	end

	return false
end

-- Recursively resolve dependencies, given the installed mods
local function resolve_dependencies_2(raw_deps, installed_mods, out)
	local function resolve_dep(dep)
		-- Check whether it's already installed
		if installed_mods[dep.name] then
			return {
				is_optional = dep.is_optional,
				name = dep.name,
				installed = true,
			}
		end

		-- Find exact name matches
		local fallback
		for _, package in pairs(dep.packages) do
			if package.type ~= "game" then
				if package.name == dep.name then
					return {
						is_optional = dep.is_optional,
						name = dep.name,
						installed = false,
						package = package,
					}
				elseif not fallback then
					fallback = package
				end
			end
		end

		-- Otherwise, find the first mod that fulfills it
		if fallback then
			return {
				is_optional = dep.is_optional,
				name = dep.name,
				installed = false,
				package = fallback,
			}
		end

		return {
			is_optional = dep.is_optional,
			name = dep.name,
			installed = false,
		}
	end

	for _, dep in pairs(raw_deps) do
		if not dep.is_optional and not out[dep.name] then
			local result  = resolve_dep(dep)
			out[dep.name] = result
			if result and result.package and not result.installed then
				local raw_deps2 = get_raw_dependencies(result.package)
				if raw_deps2 then
					resolve_dependencies_2(raw_deps2, installed_mods, out)
				end
			end
		end
	end

	return true
end

-- Resolve dependencies for a package, calls the recursive version.
local function resolve_dependencies(raw_deps, game)
	assert(game)

	local installed_mods = {}

	local mods = {}
	pkgmgr.get_game_mods(game, mods)
	for _, mod in pairs(mods) do
		installed_mods[mod.name] = true
	end

	for _, mod in pairs(pkgmgr.global_mods:get_list()) do
		installed_mods[mod.name] = true
	end

	local out = {}
	if not resolve_dependencies_2(raw_deps, installed_mods, out) then
		return nil
	end

	local retval = {}
	for _, dep in pairs(out) do
		retval[#retval + 1] = dep
	end

	table.sort(retval, function(a, b)
		return a.name < b.name
	end)

	return retval
end

local install_dialog = {}
function install_dialog.get_formspec()
	local selected_game, selected_game_idx = pkgmgr.find_by_gameid(core.settings:get("menu_last_game"))
	if not selected_game_idx then
		selected_game_idx = 1
		selected_game = pkgmgr.games[1]
	end

	local game_list = {}
	for i, game in ipairs(pkgmgr.games) do
		game_list[i] = core.formspec_escape(game.title)
	end

	local package = install_dialog.package
	local raw_deps = install_dialog.raw_deps
	local will_install_deps = install_dialog.will_install_deps

	local deps_to_install = 0
	local deps_not_found = 0

	install_dialog.dependencies = resolve_dependencies(raw_deps, selected_game)
	local formatted_deps = {}
	for _, dep in pairs(install_dialog.dependencies) do
		formatted_deps[#formatted_deps + 1] = "#fff"
		formatted_deps[#formatted_deps + 1] = core.formspec_escape(dep.name)
		if dep.installed then
			formatted_deps[#formatted_deps + 1] = "#ccf"
			formatted_deps[#formatted_deps + 1] = fgettext("Already installed")
		elseif dep.package then
			formatted_deps[#formatted_deps + 1] = "#cfc"
			formatted_deps[#formatted_deps + 1] = fgettext("$1 by $2", dep.package.title, dep.package.author)
			deps_to_install = deps_to_install + 1
		else
			formatted_deps[#formatted_deps + 1] = "#f00"
			formatted_deps[#formatted_deps + 1] = fgettext("Not found")
			deps_not_found = deps_not_found + 1
		end
	end

	local message_bg = "#3333"
	local message
	if will_install_deps then
		message = fgettext("$1 and $2 dependencies will be installed.", package.title, deps_to_install)
	else
		message = fgettext("$1 will be installed, and $2 dependencies will be skipped.", package.title, deps_to_install)
	end
	if deps_not_found > 0 then
		message = fgettext("$1 required dependencies could not be found.", deps_not_found) ..
				" " .. fgettext("Please check that the base game is correct.", deps_not_found) ..
				"\n" .. message
		message_bg = mt_color_orange
	end

	local formspec = {
		"formspec_version[3]",
		"size[7,7.85]",
		"style[title;border=false]",
		"box[0,0;7,0.5;#3333]",
		"button[0,0;7,0.5;title;", fgettext("Install $1", package.title) , "]",

		"container[0.375,0.70]",

		"label[0,0.25;", fgettext("Base Game:"), "]",
		"dropdown[2,0;4.25,0.5;selected_game;", table.concat(game_list, ","), ";", selected_game_idx, "]",

		"label[0,0.8;", fgettext("Dependencies:"), "]",

		"tablecolumns[color;text;color;text]",
		"table[0,1.1;6.25,3;packages;", table.concat(formatted_deps, ","), "]",

		"container_end[]",

		"checkbox[0.375,5.1;will_install_deps;",
			fgettext("Install missing dependencies"), ";",
			will_install_deps and "true" or "false", "]",

		"box[0,5.4;7,1.2;", message_bg, "]",
		"textarea[0.375,5.5;6.25,1;;;", message, "]",

		"container[1.375,6.85]",
		"button[0,0;2,0.8;install_all;", fgettext("Install"), "]",
		"button[2.25,0;2,0.8;cancel;", fgettext("Cancel"), "]",
		"container_end[]",
	}

	return table.concat(formspec)
end

function install_dialog.handle_submit(this, fields)
	if fields.cancel then
		this:delete()
		return true
	end

	if fields.will_install_deps ~= nil then
		install_dialog.will_install_deps = core.is_yes(fields.will_install_deps)
		return true
	end

	if fields.install_all then
		queue_download(install_dialog.package, REASON_NEW)

		if install_dialog.will_install_deps then
			for _, dep in pairs(install_dialog.dependencies) do
				if not dep.is_optional and not dep.installed and dep.package then
					queue_download(dep.package, REASON_DEPENDENCY)
				end
			end
		end

		this:delete()
		return true
	end

	if fields.selected_game then
		for _, game in pairs(pkgmgr.games) do
			if game.title == fields.selected_game then
				core.settings:set("menu_last_game", game.id)
				break
			end
		end
		return true
	end

	return false
end

function install_dialog.create(package, raw_deps)
	install_dialog.dependencies = nil
	install_dialog.package = package
	install_dialog.raw_deps = raw_deps
	install_dialog.will_install_deps = true
	return dialog_create("install_dialog",
			install_dialog.get_formspec,
			install_dialog.handle_submit,
			nil)
end


local confirm_overwrite = {}
function confirm_overwrite.get_formspec()
	local package = confirm_overwrite.package

	return confirmation_formspec(
		fgettext("\"$1\" already exists. Would you like to overwrite it?", package.name),
		'install', fgettext("Overwrite"),
		'cancel', fgettext("Cancel"))
end

function confirm_overwrite.handle_submit(this, fields)
	if fields.cancel then
		this:delete()
		return true
	end

	if fields.install then
		this:delete()
		confirm_overwrite.callback()
		return true
	end

	return false
end

function confirm_overwrite.create(package, callback)
	assert(type(package) == "table")
	assert(type(callback) == "function")

	confirm_overwrite.package = package
	confirm_overwrite.callback = callback
	return dialog_create("confirm_overwrite",
		confirm_overwrite.get_formspec,
		confirm_overwrite.handle_submit,
		nil)
end

local function install_or_update_package(this, package)
	local install_parent
	if package.type == "mod" then
		install_parent = core.get_modpath()
	elseif package.type == "game" then
		install_parent = core.get_gamepath()
	elseif package.type == "txp" then
		install_parent = core.get_texturepath()
	else
		error("Unknown package type: " .. package.type)
	end

	if package.queued or package.downloading then
		return
	end

	local function on_confirm()
		local deps = get_raw_dependencies(package)
		if deps and has_hard_deps(deps) then
			local dlg = install_dialog.create(package, deps)
			dlg:set_parent(this)
			this:hide()
			dlg:show()
		else
			queue_download(package, package.path and REASON_UPDATE or REASON_NEW)
		end
	end

	if package.type == "mod" and #pkgmgr.games == 0 then
		local dlg = messagebox("install_game",
			fgettext("You need to install a game before you can install a mod"))
		dlg:set_parent(this)
		this:hide()
		dlg:show()
	elseif not package.path and core.is_dir(install_parent .. DIR_DELIM .. package.name) then
		local dlg = confirm_overwrite.create(package, on_confirm)
		dlg:set_parent(this)
		this:hide()
		dlg:show()
	else
		on_confirm()
	end
end


local function get_file_extension(path)
	local parts = path:split(".")
	return parts[#parts]
end

local function get_screenshot(package)
	if not package.thumbnail then
		return defaulttexturedir .. "no_screenshot.png"
	elseif screenshot_downloading[package.thumbnail] then
		return defaulttexturedir .. "loading_screenshot.png"
	end

	-- Get tmp screenshot path
	local ext = get_file_extension(package.thumbnail)
	local filepath = screenshot_dir .. DIR_DELIM ..
		("%s-%s-%s.%s"):format(package.type, package.author, package.name, ext)

	-- Return if already downloaded
	local file = io.open(filepath, "r")
	if file then
		file:close()
		return filepath
	end

	-- Show error if we've failed to download before
	if screenshot_downloaded[package.thumbnail] then
		return defaulttexturedir .. "error_screenshot.png"
	end

	-- Download

	local function download_screenshot(params)
		return core.download_file(params.url, params.dest)
	end
	local function callback(success)
		screenshot_downloading[package.thumbnail] = nil
		screenshot_downloaded[package.thumbnail] = true
		if not success then
			core.log("warning", "Screenshot download failed for some reason")
		end
		ui.update()
	end
	if core.handle_async(download_screenshot,
			{ dest = filepath, url = package.thumbnail }, callback) then
		screenshot_downloading[package.thumbnail] = true
	else
		core.log("error", "ERROR: async event failed")
		return defaulttexturedir .. "error_screenshot.png"
	end

	return defaulttexturedir .. "loading_screenshot.png"
end

local function fetch_pkgs()
	local version = core.get_version()
	local base_url = core.settings:get("contentdb_url")
	local url = base_url ..
		"/api/packages/?type=mod&type=game&type=txp&protocol_version=" ..
		core.get_max_supp_proto() .. "&engine_version=" .. core.urlencode(version.string)

	for _, item in pairs(core.settings:get("contentdb_flag_blacklist"):split(",")) do
		item = item:trim()
		if item ~= "" then
			url = url .. "&hide=" .. core.urlencode(item)
		end
	end

	local http = core.get_http_api()
	local response = http.fetch_sync({ url = url })
	if not response.succeeded then
		return
	end

	local packages = core.parse_json(response.data)
	if not packages or #packages == 0 then
		return
	end
	local aliases = {}

	for _, package in pairs(packages) do
		local name_len = #package.name
		-- This must match what store.update_paths() does!
		package.id = package.author:lower() .. "/"
		if package.type == "game" and name_len > 5 and package.name:sub(name_len - 4) == "_game" then
			package.id = package.id .. package.name:sub(1, name_len - 5)
		else
			package.id = package.id .. package.name
		end

		package.url_part = core.urlencode(package.author) .. "/" .. core.urlencode(package.name)

		if package.aliases then
			for _, alias in ipairs(package.aliases) do
				-- We currently don't support name changing
				local suffix = "/" .. package.name
				if alias:sub(-#suffix) == suffix then
					aliases[alias:lower()] = package.id
				end
			end
		end
	end

	return { packages = packages, aliases = aliases }
end

local function sort_and_filter_pkgs()
	store.update_paths()
	store.sort_packages()
	store.filter_packages(search_string)
end

-- Resolves the package specification stored in auto_install_spec into an actual package.
-- May only be called after the package list has been loaded successfully.
local function resolve_auto_install_spec()
	assert(store.load_ok)

	if not auto_install_spec then
		return nil
	end

	local resolved = nil

	for _, pkg in ipairs(store.packages_full_unordered) do
		if pkg.id == auto_install_spec then
			resolved = pkg
			break
		end
	end

	if not resolved then
		gamedata.errormessage = fgettext("The package $1/$2 was not found.",
				auto_install_spec.author, auto_install_spec.name)
		ui.update()

		auto_install_spec = nil
	end

	return resolved
end

-- Installs the package specified by auto_install_spec.
-- Only does something if:
-- a. The package list has been loaded successfully.
-- b. The store dialog is currently visible.
local function do_auto_install()
	if not store.load_ok then
		return
	end

	local pkg = resolve_auto_install_spec()
	if not pkg then
		return
	end

	local store_dlg = ui.find_by_name("store")
	if not store_dlg or store_dlg.hidden then
		return
	end

	install_or_update_package(store_dlg, pkg)
	auto_install_spec = nil
end

function store.load()
	if store.load_ok then
		sort_and_filter_pkgs()
		return
	end
	if store.loading then
		return
	end
	store.loading = true
	core.handle_async(
		fetch_pkgs,
		nil,
		function(result)
			if result then
				store.load_ok = true
				store.load_error = false
				store.packages = result.packages
				store.packages_full = result.packages
				store.packages_full_unordered = result.packages
				store.aliases = result.aliases

				sort_and_filter_pkgs()
				do_auto_install()
			else
				store.load_error = true
			end

			store.loading = false
			ui.update()
		end
	)
end

function store.update_paths()
	local mod_hash = {}
	pkgmgr.refresh_globals()
	for _, mod in pairs(pkgmgr.global_mods:get_list()) do
		local cdb_id = pkgmgr.get_contentdb_id(mod)
		if cdb_id then
			mod_hash[store.aliases[cdb_id] or cdb_id] = mod
		end
	end

	local game_hash = {}
	pkgmgr.update_gamelist()
	for _, game in pairs(pkgmgr.games) do
		local cdb_id = pkgmgr.get_contentdb_id(game)
		if cdb_id then
			game_hash[store.aliases[cdb_id] or cdb_id] = game
		end
	end

	local txp_hash = {}
	for _, txp in pairs(pkgmgr.get_texture_packs()) do
		local cdb_id = pkgmgr.get_contentdb_id(txp)
		if cdb_id then
			txp_hash[store.aliases[cdb_id] or cdb_id] = txp
		end
	end

	for _, package in pairs(store.packages_full) do
		local content
		if package.type == "mod" then
			content = mod_hash[package.id]
		elseif package.type == "game" then
			content = game_hash[package.id]
		elseif package.type == "txp" then
			content = txp_hash[package.id]
		end

		if content then
			package.path = content.path
			package.installed_release = content.release or 0
		else
			package.path = nil
			package.installed_release = nil
		end
	end
end

function store.sort_packages()
	local ret = {}

	local auto_install_pkg = resolve_auto_install_spec() -- can be nil

	-- Add installed content
	for _, pkg in ipairs(store.packages_full_unordered) do
		if pkg.path and pkg ~= auto_install_pkg then
			ret[#ret + 1] = pkg
		end
	end

	-- Sort installed content first by "is there an update available?", then by title
	table.sort(ret, function(a, b)
		local a_updatable = a.installed_release < a.release
		local b_updatable = b.installed_release < b.release
		if a_updatable and not b_updatable then
			return true
		elseif b_updatable and not a_updatable then
			return false
		end

		return a.title < b.title
	end)

	-- Add uninstalled content
	for _, pkg in ipairs(store.packages_full_unordered) do
		if not pkg.path and pkg ~= auto_install_pkg then
			ret[#ret + 1] = pkg
		end
	end

	-- Put the package that will be auto-installed at the very top
	if auto_install_pkg then
		table.insert(ret, 1, auto_install_pkg)
	end

	store.packages_full = ret
end

function store.filter_packages(query)
	if query == "" and filter_type == 1 then
		store.packages = store.packages_full
		return
	end

	local keywords = {}
	for word in query:lower():gmatch("%S+") do
		table.insert(keywords, word)
	end

	local function matches_keywords(package)
		for k = 1, #keywords do
			local keyword = keywords[k]

			if string.find(package.name:lower(), keyword, 1, true) or
					string.find(package.title:lower(), keyword, 1, true) or
					string.find(package.author:lower(), keyword, 1, true) or
					string.find(package.short_description:lower(), keyword, 1, true) then
				return true
			end
		end

		return false
	end

	store.packages = {}
	for _, package in pairs(store.packages_full) do
		if (query == "" or matches_keywords(package)) and
				(filter_type == 1 or package.type == filter_types_type[filter_type]) then
			store.packages[#store.packages + 1] = package
		end
	end
end

local function get_info_formspec(text)
	local H = 9.5
	return table.concat({
		"formspec_version[6]",
		"size[15.75,9.5]",
		TOUCHSCREEN_GUI and "padding[0.01,0.01]" or "position[0.5,0.55]",

		"label[4,4.35;", text, "]",
		"container[0,", H - 0.8 - 0.375, "]",
		"button[0.375,0;5,0.8;back;", fgettext("Back to Main Menu"), "]",
		"container_end[]",
	})
end

function store.get_formspec(dlgdata)
	if store.loading then
		return get_info_formspec(fgettext("Loading..."))
	end
	if store.load_error then
		return get_info_formspec(fgettext("No packages could be retrieved"))
	end
	assert(store.load_ok)

	store.update_paths()

	dlgdata.pagemax = math.max(math.ceil(#store.packages / num_per_page), 1)
	if cur_page > dlgdata.pagemax then
		cur_page = 1
	end

	local W = 15.75
	local H = 9.5
	local formspec = {
		"formspec_version[6]",
		"size[15.75,9.5]",
		TOUCHSCREEN_GUI and "padding[0.01,0.01]" or "position[0.5,0.55]",

		"style[status,downloading,queued;border=false]",

		"container[0.375,0.375]",
		"field[0,0;7.225,0.8;search_string;;", core.formspec_escape(search_string), "]",
		"field_enter_after_edit[search_string;true]",
		"image_button[7.3,0;0.8,0.8;", core.formspec_escape(defaulttexturedir .. "search.png"), ";search;]",
		"image_button[8.125,0;0.8,0.8;", core.formspec_escape(defaulttexturedir .. "clear.png"), ";clear;]",
		"dropdown[9.175,0;2.7875,0.8;type;", table.concat(filter_types_titles, ","), ";", filter_type, "]",
		"container_end[]",

		-- Page nav buttons
		"container[0,", H - 0.8 - 0.375, "]",
		"button[0.375,0;5,0.8;back;", fgettext("Back to Main Menu"), "]",

		"container[", W - 0.375 - 0.8*4 - 2,  ",0]",
		"image_button[0,0;0.8,0.8;", core.formspec_escape(defaulttexturedir), "start_icon.png;pstart;]",
		"image_button[0.8,0;0.8,0.8;", core.formspec_escape(defaulttexturedir), "prev_icon.png;pback;]",
		"style[pagenum;border=false]",
		"button[1.6,0;2,0.8;pagenum;", tonumber(cur_page), " / ", tonumber(dlgdata.pagemax), "]",
		"image_button[3.6,0;0.8,0.8;", core.formspec_escape(defaulttexturedir), "next_icon.png;pnext;]",
		"image_button[4.4,0;0.8,0.8;", core.formspec_escape(defaulttexturedir), "end_icon.png;pend;]",
		"container_end[]",

		"container_end[]",
	}

	if number_downloading > 0 then
		formspec[#formspec + 1] = "button[12.5875,0.375;2.7875,0.8;downloading;"
		if #download_queue > 0 then
			formspec[#formspec + 1] = fgettext("$1 downloading,\n$2 queued", number_downloading, #download_queue)
		else
			formspec[#formspec + 1] = fgettext("$1 downloading...", number_downloading)
		end
		formspec[#formspec + 1] = "]"
	else
		local num_avail_updates = 0
		for i=1, #store.packages_full do
			local package = store.packages_full[i]
			if package.path and package.installed_release < package.release and
					not (package.downloading or package.queued) then
				num_avail_updates = num_avail_updates + 1
			end
		end

		if num_avail_updates == 0 then
			formspec[#formspec + 1] = "button[12.5875,0.375;2.7875,0.8;status;"
			formspec[#formspec + 1] = fgettext("No updates")
			formspec[#formspec + 1] = "]"
		else
			formspec[#formspec + 1] = "button[12.5875,0.375;2.7875,0.8;update_all;"
			formspec[#formspec + 1] = fgettext("Update All [$1]", num_avail_updates)
			formspec[#formspec + 1] = "]"
		end
	end

	if #store.packages == 0 then
		formspec[#formspec + 1] = "label[4,4.75;"
		formspec[#formspec + 1] = fgettext("No results")
		formspec[#formspec + 1] = "]"
	end

	-- download/queued tooltips always have the same message
	local tooltip_colors = ";#dff6f5;#302c2e]"
	formspec[#formspec + 1] = "tooltip[downloading;" .. fgettext("Downloading...") .. tooltip_colors
	formspec[#formspec + 1] = "tooltip[queued;" .. fgettext("Queued") .. tooltip_colors

	local start_idx = (cur_page - 1) * num_per_page + 1
	for i=start_idx, math.min(#store.packages, start_idx+num_per_page-1) do
		local package = store.packages[i]
		local container_y = (i - start_idx) * 1.375 + (2*0.375 + 0.8)
		formspec[#formspec + 1] = "container[0.375,"
		formspec[#formspec + 1] = container_y
		formspec[#formspec + 1] = "]"

		-- image
		formspec[#formspec + 1] = "image[0,0;1.5,1;"
		formspec[#formspec + 1] = core.formspec_escape(get_screenshot(package))
		formspec[#formspec + 1] = "]"

		-- title
		formspec[#formspec + 1] = "label[1.875,0.1;"
		formspec[#formspec + 1] = core.formspec_escape(
				core.colorize(mt_color_green, package.title) ..
				core.colorize("#BFBFBF", " by " .. package.author))
		formspec[#formspec + 1] = "]"

		-- buttons
		local description_width = W - 2.625 - 2 * 0.7 - 2 * 0.15

		local second_base = "image_button[-1.55,0;0.7,0.7;" .. core.formspec_escape(defaulttexturedir)
		local third_base = "image_button[-2.4,0;0.7,0.7;" .. core.formspec_escape(defaulttexturedir)
		formspec[#formspec + 1] = "container["
		formspec[#formspec + 1] = W - 0.375*2
		formspec[#formspec + 1] = ",0.1]"

		if package.downloading then
			formspec[#formspec + 1] = "animated_image[-1.7,-0.15;1,1;downloading;"
			formspec[#formspec + 1] = core.formspec_escape(defaulttexturedir)
			formspec[#formspec + 1] = "cdb_downloading.png;3;400;]"
		elseif package.queued then
			formspec[#formspec + 1] = second_base
			formspec[#formspec + 1] = "cdb_queued.png;queued;]"
		elseif not package.path then
			local elem_name = "install_" .. i .. ";"
			formspec[#formspec + 1] = "style[" .. elem_name .. "bgcolor=#71aa34]"
			formspec[#formspec + 1] = second_base .. "cdb_add.png;" .. elem_name .. "]"
			formspec[#formspec + 1] = "tooltip[" .. elem_name .. fgettext("Install") .. tooltip_colors
		else
			if package.installed_release < package.release then
				-- The install_ action also handles updating
				local elem_name = "install_" .. i .. ";"
				formspec[#formspec + 1] = "style[" .. elem_name .. "bgcolor=#28ccdf]"
				formspec[#formspec + 1] = third_base .. "cdb_update.png;" .. elem_name .. "]"
				formspec[#formspec + 1] = "tooltip[" .. elem_name .. fgettext("Update") .. tooltip_colors

				description_width = description_width - 0.7 - 0.15
			end

			local elem_name = "uninstall_" .. i .. ";"
			formspec[#formspec + 1] = "style[" .. elem_name .. "bgcolor=#a93b3b]"
			formspec[#formspec + 1] = second_base .. "cdb_clear.png;" .. elem_name .. "]"
			formspec[#formspec + 1] = "tooltip[" .. elem_name .. fgettext("Uninstall") .. tooltip_colors
		end

		local web_elem_name = "view_" .. i .. ";"
		formspec[#formspec + 1] = "image_button[-0.7,0;0.7,0.7;" ..
			core.formspec_escape(defaulttexturedir) .. "cdb_viewonline.png;" .. web_elem_name .. "]"
		formspec[#formspec + 1] = "tooltip[" .. web_elem_name ..
			fgettext("View more information in a web browser") .. tooltip_colors
		formspec[#formspec + 1] = "container_end[]"

		-- description
		formspec[#formspec + 1] = "textarea[1.855,0.3;"
		formspec[#formspec + 1] = tostring(description_width)
		formspec[#formspec + 1] = ",0.8;;;"
		formspec[#formspec + 1] = core.formspec_escape(package.short_description)
		formspec[#formspec + 1] = "]"

		formspec[#formspec + 1] = "container_end[]"
	end

	return table.concat(formspec)
end

function store.handle_submit(this, fields)
	if fields.search or fields.key_enter_field == "search_string" then
		search_string = fields.search_string:trim()
		cur_page = 1
		store.filter_packages(search_string)
		return true
	end

	if fields.clear then
		search_string = ""
		cur_page = 1
		store.filter_packages("")
		return true
	end

	if fields.back then
		this:delete()
		return true
	end

	if fields.pstart then
		cur_page = 1
		return true
	end

	if fields.pend then
		cur_page = this.data.pagemax
		return true
	end

	if fields.pnext then
		cur_page = cur_page + 1
		if cur_page > this.data.pagemax then
			cur_page = 1
		end
		return true
	end

	if fields.pback then
		if cur_page == 1 then
			cur_page = this.data.pagemax
		else
			cur_page = cur_page - 1
		end
		return true
	end

	if fields.type then
		local new_type = table.indexof(filter_types_titles, fields.type)
		if new_type ~= filter_type then
			filter_type = new_type
			cur_page = 1
			store.filter_packages(search_string)
			return true
		end
	end

	if fields.update_all then
		for i=1, #store.packages_full do
			local package = store.packages_full[i]
			if package.path and package.installed_release < package.release and
					not (package.downloading or package.queued) then
				queue_download(package, REASON_UPDATE)
			end
		end
		return true
	end

	local start_idx = (cur_page - 1) * num_per_page + 1
	assert(start_idx ~= nil)
	for i=start_idx, math.min(#store.packages, start_idx+num_per_page-1) do
		local package = store.packages[i]
		assert(package)

		if fields["install_" .. i] then
			install_or_update_package(this, package)
			return true
		end

		if fields["uninstall_" .. i] then
			local dlg = create_delete_content_dlg(package)
			dlg:set_parent(this)
			this:hide()
			dlg:show()
			return true
		end

		if fields["view_" .. i] then
			local url = ("%s/packages/%s?protocol_version=%d"):format(
					core.settings:get("contentdb_url"), package.url_part,
					core.get_max_supp_proto())
			core.open_url(url)
			return true
		end
	end

	return false
end

function store.handle_events(event)
	if event == "DialogShow" then
		-- On mobile, don't show the "MINETEST" header behind the dialog.
		mm_game_theme.set_engine(TOUCHSCREEN_GUI)

		-- If the store is already loaded, auto-install packages here.
		do_auto_install()

		return true
	end

	return false
end

--- Creates a ContentDB dialog.
---
--- @param type string | nil
--- Sets initial package filter. "game", "mod", "txp" or nil (no filter).
--- @param install_spec table | nil
--- ContentDB ID of package as returned by pkgmgr.get_contentdb_id().
--- Sets package to install or update automatically.
function create_store_dlg(type, install_spec)
	search_string = ""
	cur_page = 1
	if type then
		-- table.indexof does not work on tables that contain `nil`
		for i, v in pairs(filter_types_type) do
			if v == type then
				filter_type = i
				break
			end
		end
	else
		filter_type = 1
	end

	-- Keep the old auto_install_spec if the caller doesn't specify one.
	if install_spec then
		auto_install_spec = install_spec
	end

	store.load()

	return dialog_create("store",
			store.get_formspec,
			store.handle_submit,
			store.handle_events)
end
