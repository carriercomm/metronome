local datamanager = require "util.datamanager"
local dataforms_new = require "util.dataforms".new
local jid_split = require "util.jid".split
local jid_bare = require "util.jid".bare
local restrict_to_host = module:get_option_set("restrict_to_hosts")
local ud_disco_name = module:get_option_string("ud_disco_name", "Metronome User Directory")
local st = require "util.stanza"

module:depends("adhoc")

directory = {}
local my_host = module:get_host()

if datamanager.load("store", my_host, "directory") then
	directory = datamanager.load("store", module:get_host(), "directory")
end
local function search_form_layout()
	return dataforms_new{
		title = "Directory Search";
		instructions = "This let's you browse the User Directory, your client MUST support Data Forms.";

		{ name = "FORM_TYPE", type = "hidden", value = "jabber:iq:search" };
		{ name = "nickname", type = "text-single", label = "Nickname" };
		{ name = "realname", type = "text-single", label = "Real name" };
		{ name = "country", type = "text-single", label = "Country name" };
		{ name = "email", type = "text-single", label = "E-Mail address" };
	}
end
local function escape_magic(string)
	-- escape magic characters
	string = string:gsub("%(", "%%(")
	string = string:gsub("%)", "%%)")
	string = string:gsub("%.", "%%.")
	string = string:gsub("%%", "%%")
	string = string:gsub("%+", "%%+")
	string = string:gsub("%-", "%%-")
	string = string:gsub("%*", "%%*")
	string = string:gsub("%?", "%%?")
	string = string:gsub("%[", "%%[")
	string = string:gsub("%]", "%%]")
	string = string:gsub("%^", "%%^")
	string = string:gsub("%$", "%%$")

	return string
end

local function search_get_handler(event)
	local origin, stanza = event.origin, event.stanza
	local reply = st.reply(stanza)
	reply:query("jabber:iq:search"):add_child(search_form_layout():form())
	
	return origin.send(reply)
end

local function search_process_handler(event)
	local form, matching_results, params, origin, stanza = nil, {}, {}, event.origin, event.stanza
	
	for _, tag in ipairs(stanza.tags[1].tags) do if tag.name == "x" and tag.attr.xmlns == "jabber:x:data" then form = tag; break; end end
	if not form then origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); return end

	if form.attr.type == "cancel" then origin.send(st.reply(stanza)); return end
	if form.attr.type ~= "submit" then origin.send(st.error_reply(stanza, "cancel", "bad-request", "You need to submit the search form.")); return end

	local fields = search_form_layout():data(form);
	if fields.FORM_TYPE ~= "jabber:iq:search" then 
		origin.send(st.error_reply(stanza, "cancel", "bad-request", "Not a search form")) 
		return 
	end

	if fields.nickname then params.nickname = true end
	if fields.realname then params.realname = true end
	if fields.country then params.country = true end
	if fields.email then params.email = true end
	
	for jid, details in pairs(directory) do
		local dummy = {}
		for f, b in pairs(params) do
			dummy[f] = b
		end

		if dummy.nickname and not details.nickname:match(escape_magic(fields.nickname)) then dummy.nickname = false end
		if dummy.realname and not details.realname:match(escape_magic(fields.realname)) then dummy.realname = false end
		if dummy.country and not details.country:match(escape_magic(fields.country)) then dummy.country = false end
		if dummy.email and not details.email:match(escape_magic(fields.email)) then dummy.email = false end

		for _, check in pairs(dummy) do if not check then dummy = false; break end end
		if dummy and next(dummy) then
			matching_results[#matching_results + 1] = { 
				jid = jid,
				nickname = details.nickname,
				realname = details.realname,
				country = details.country,
				email = details.email
			}
		end
	end

	if #matching_results > 0 then
		local reply = st.reply(stanza)
		
		reply:query("jabber:iq:search")
			:tag("x", { xmlns = "jabber:x:data", type = "result" })
				:tag("field", { var = "FORM_TYPE", type = "hidden" })
					:tag("value"):text("jabber:iq:search"):up():up()
				:tag("reported")
					:tag("field", { var = "jid", label = "JID", type = "text-single" }):up()
					:tag("field", { var = "nickname", label = "Nickname", type = "text-single" }):up()
					:tag("field", { var = "realname", label = "Real name", type = "text-single" }):up()
					:tag("field", { var = "country", label = "Country", type = "text-single" }):up()
					:tag("field", { var = "email", label = "E-Mail Address", type = "text-single" }):up():up():up();

		for _, data in ipairs(matching_results) do
			reply:get_child("query", "jabber:iq:search"):get_child("x", "jabber:x:data")
				:tag("item")
					:tag("field", { var = "jid" }):tag("value"):text(data.jid):up():up()
					:tag("field", { var = "nickname" }):tag("value"):text(data.nickname):up():up()
					:tag("field", { var = "realname" }):tag("value"):text(data.realname):up():up()
					:tag("field", { var = "country" }):tag("value"):text(data.country):up():up()
					:tag("field", { var = "email" }):tag("value"):text(data.email):up():up():up();
		end

		return origin.send(reply)
	else
		return origin.send(st.reply(stanza):query("jabber:iq:search"))
	end				
end

local function disco_handler(event)
	local origin, stanza = event.origin, event.stanza
	
	local disco_reply = st.reply(stanza):query("http://jabber.org/protocol/disco#info")
		:tag("identity", { category = "directory", type = "user", name = ud_disco_name }):up()
		:tag("feature", { var = "http://jabber.org/protocol/commands" }):up()
		:tag("feature", { var = "http://jabber.org/protocol/disco#info" }):up()
		:tag("feature", { var = "jabber:iq:search" }):up();

	return origin.send(disco_reply)
end

module:hook("iq-get/host/jabber:iq:search:query", search_get_handler)
module:hook("iq-get/host/http://jabber.org/protocol/disco#info:query", disco_handler)
module:hook("iq-set/host/jabber:iq:search:query", search_process_handler)

--- Adhoc Handlers

local function optin_command_handler(self, data, state)
	local optin_layout = dataforms_new{
		title = "Signup/Optin form for the User Directory";
		instructions = "At least the Nickname field is required.";

		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/commands" };
		{ name = "nickname", type = "text-single", label = "Your Nickname" };
		{ name = "realname", type = "text-single", label = "Real name" };
		{ name = "country", type = "text-single", label = "Your country name" };
		{ name = "email", type = "text-single", label = "Your E-Mail address" };
	}

	if state then
		if data.action == "cancel" then return { status = "canceled" } end
		local fields = optin_layout:data(data.form)
		if restrict_to_host then
			local node, host = jid_split(data.from)
			if not restrict_to_hosts:contains(host) then return { status = completed, error = { message = "Signup to this directory is restricted." } } end
		end
		if not fields.nickname and not fields.realname and not fields.country and not fields.email then
			return { status = "completed", error = { message = "You need to fill at least one field." } }
		else
			if not directory[jid_bare(data.from)] then
				directory[jid_bare(data.from)] = { nickname = fields.nickname or "", realname = fields.realname or "", country = fields.country or "", email = fields.email or "" }
				if datamanager.store("store", my_host, "directory", directory) then
					return { status = "completed", info = "Success." }
				else
					return { status = "completed", error = { message = "Adding was successful but I failed to write to the directory store, please report to the admin." } }
				end
			else
				return { status = "completed", error = { message = "You have already opted in, please opt out first, if you want to change your data." } }
			end
		end
	else
		return { status = "executing", form = optin_layout }, "executing"
	end
end

local function optout_command_handler(self, data, state)
	if directory[jid_bare(data.from)] then
		directory[jid_bare(data.from)] = nil
		if datamanager.store("store", my_host, "directory", directory) then
			return { status = "completed", info = "You have been removed from the user directory." }
		else
			return { status = "completed", error = { message = "Removal was successful but I failed to write to the directory store, please report to the admin." } }
		end		
	else
		return { status = "completed", error = { message = "You need to optin first!" } }
	end
end

local adhoc_new = module:require "adhoc".new
local optin_descriptor = adhoc_new("Optin for the user search directory", "optin", optin_command_handler)
local optout_descriptor = adhoc_new("Optout for the user search directory", "optout", optout_command_handler)
module:provides("adhoc", optin_descriptor)
module:provides("adhoc", optout_descriptor)

module.save = function() return { directory = directory } end
module.restore = function(data) directory = data.directory or {} end