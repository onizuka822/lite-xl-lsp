-- mod-version:1 lite-xl 1.16
--
-- LSP client for lite-xl
-- @copyright Jefferson Gonzalez
-- @license MIT

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local Doc = require "core.doc"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local RootView = require "core.rootview"
local DocView = require "core.docview"

local Json = require "plugins.lsp.json"
local Server = require "plugins.lsp.server"
local Util = require "plugins.lsp.util"
local autocomplete = require "plugins.autocomplete"

--
-- Plugin settings
--
config.lsp = {}

-- Set to a file to log all json
config.lsp.log_file = ""

-- Set to true break json for more readability on the log
config.lsp.prettify_json = false

--
-- Main plugin functionality
--
local lsp = {}

lsp.servers = {}
lsp.servers_running = {}

local function matches_any(filename, patterns)
  for _, ptn in ipairs(patterns) do
    if filename:find(ptn) then
      return true
    end
  end
end

local function get_buffer_position_params(doc, line, col)
  return {
    textDocument = {
      uri = Util.touri(system.absolute_path(doc.filename)),
    },
    position = {
      line = line - 1,
      character = col - 1
    }
  }
end

local function log(server, message, ...)
  core.log("["..server.name.."] " .. message, ...)
end

function lsp.add_server(server)
  lsp.servers[server.name] = server
end

function lsp.get_active_servers(filename)
  local servers = {}
  for name, server in pairs(lsp.servers) do
    if matches_any(filename, server.file_patterns) then
      if lsp.servers_running[name] then
        table.insert(servers, name)
      end
    end
  end
  return servers
end

function lsp.start_server(filename, project_directory)
  for name, server in pairs(lsp.servers) do
    if matches_any(filename, server.file_patterns) then
      if not lsp.servers_running[name] then
        core.log("[LSP] starting " .. name)
        local client = Server.new(server)

        lsp.servers_running[name] = client

        -- we overwrite the default log function
        function client:log(message, ...)
          core.log_quiet(
            "[LSP/%s]: " .. message .. "\n",
            self.name,
            ...
          )
        end

        client:add_message_listener("window/logMessage", function(server, params)
          if core.log then
            core.log("["..server.name.."] " .. params.message)
            coroutine.yield(3)
          end
        end)

        client:add_event_listener("initialized", function(server, ...)
          core.log("["..server.name.."] " .. "Initialized")
          if server.settings then
            server:push_request(
              "workspace/didChangeConfiguration",
              {settings = server.settings},
              function(server, response)
                if server.verbose then
                  server:log(
                    "Completion response: %s",
                    Util.jsonprettify(Json.encode(response))
                  )
                end
              end
            )
          end
          if server.capabilities then
            if
              server.capabilities.completionProvider
              and
              server.capabilities.completionProvider.triggerCharacters
            then
              if server.verbose then
                server:log(
                  "Adding triggers for '%s' - %s",
                  server.language,
                  table.concat(
                    server.capabilities
                      .completionProvider.triggerCharacters,
                    ", "
                  )
                )
              end
              autocomplete.add_trigger {
                name = server.language,
                file_patterns = server.file_patterns,
                characters = server.capabilities
                  .completionProvider.triggerCharacters
              }
            end
          end
        end)

        client:initialize(
          project_directory,
          "Lite XL",
          "0.16.0"
        )
      end
    end
  end
end

function lsp.open_document(doc)
  lsp.start_server(doc.filename, core.project_dir)

  local active_servers = lsp.get_active_servers(doc.filename)

  if #active_servers > 0 then
    doc.disable_symbols = true

    for index, name in pairs(active_servers) do
      lsp.servers_running[name]:push_notification(
        'textDocument/didOpen',
        {
          textDocument = {
            uri = Util.touri(system.absolute_path(doc.filename)),
            languageId = Util.file_extension(doc.filename),
            version = doc.clean_change_id,
            text = doc:get_text(1, 1, #doc.lines, #doc.lines[#doc.lines])
          }
        }
      )
    end
  end
end

function lsp.request_completion(doc, line, col)
  for index, name in pairs(lsp.get_active_servers(doc.filename)) do
    lsp.servers_running[name]:push_notification(
      'textDocument/didChange',
      {
        textDocument = {
          uri = Util.touri(system.absolute_path(doc.filename)),
          version = doc.clean_change_id,
        },
        contentChanges = {
          {
            text = doc:get_text(1, 1, #doc.lines, #doc.lines[#doc.lines])
          }
        },
        syncKind = 1
      }
    )

    lsp.servers_running[name]:push_request(
      'textDocument/completion',
      get_buffer_position_params(doc, line, col),
      function(server, response)
        if server.verbose then
          server:log(
            "Completion response: %s",
            Util.jsonprettify(Json.encode(response))
          )
        end

        if not response.result then
          return
        end

        local result = response.result
        if result.isIncomplete then
          if server.verbose then
            core.log_quiet(
              "["..server.name.."] " .. "Completion list incomplete"
            )
          end
          return
        end

        local symbols = {
          name = lsp.servers_running[name].name,
          files = lsp.servers_running[name].file_patterns,
          items = {}
        }

        for _, symbol in ipairs(result.items) do
          local label = symbol.label
            or (
              symbol.textEdit
              and symbol.textEdit.newText
              or symbol.insertText
            )

          local info = symbol.detail
            or server.get_completion_items_kind(symbol.kind)
            or ""

          -- Fix some issues as with clangd
          if
            symbol.label and
            symbol.insertText and
            #symbol.label > #symbol.insertText
          then
            label = symbol.insertText
            info = symbol.label
            if symbol.detail then
              info = info .. ": " .. symbol.detail
            end
          end

          symbols.items[label] = info
        end

        autocomplete.complete(symbols)
      end
    )
  end
end

function lsp.goto_symbol(doc, line, col, implementation)
  for index, name in pairs(lsp.get_active_servers(doc.filename)) do
    local server = lsp.servers_running[name]

    if not server.capabilities then
      return
    end

    local method = ""
    if not implementation then
      if server.capabilities.definitionProvider then
        method = method .. "definition"
      elseif server.capabilities.declarationProvider then
        method = method .. "declaration"
      elseif server.capabilities.typeDefinitionProvider then
        method = method .. "typeDefinition"
      else
        log(server, "Goto definition not supported")
        return
      end
    else
      if server.capabilities.implementationProvider then
        method = method .. "implementation"
      else
        log(server, "Goto implementation not supported")
        return
      end
    end

    server:push_request(
      "textDocument/" .. method,
      get_buffer_position_params(doc, line, col),
      function(server, response)
        local location = response.result

        if not location or not location.uri and #location == 0 then
          log(server, "No %s found", method)
          return
        end

        -- TODO display a box showing different definition points to go
        if not location.uri then
          if #location >= 1 then
            location = location[1]
          end
        end

        -- Open first matching result and goto the line
        core.root_view:open_doc(
          core.open_doc(
            common.home_expand(Util.tofilename(location.uri))
          )
        )
        local line1, col1 = Util.toselection(location.range)
        core.active_view.doc:set_selection(line1, col1, line1, col1)
      end
    )
  end
end

function lsp.request_hover(filename, position)
  table.insert(lsp.documents, filename)
end

--
-- Thread to process server requests and responses
-- without blocking entirely the editor.
--
core.add_thread(function()
  while true do
    for name,server in pairs(lsp.servers_running) do
      server:process_notifications()
      server:process_requests()
      server:process_responses()
      server:process_errors()
    end

    if system.window_has_focus() then
      -- scan the fastest possible while not eating too much cpu
      coroutine.yield(0.01)
    else
      -- if window is unfocused lower the thread rate to lower cpu usage
      coroutine.yield(config.project_scan_rate)
    end
  end
end)

local function get_active_view()
  if getmetatable(core.active_view) == DocView then
    return core.active_view
  end
  return nil
end

--
-- Events patching
--
local doc_load = Doc.load
local root_view_on_text_input = RootView.on_text_input

Doc.load = function(self, ...)
  local res = doc_load(self, ...)
  core.add_thread(function()
    lsp.open_document(self)
  end)
  return res
end

RootView.on_text_input = function(...)
  root_view_on_text_input(...)

  local av = get_active_view()

  if av then
    local line1, col1, line2, col2 = av.doc:get_selection()

    if line1 == line2 and col1 == col2 then
      lsp.request_completion(av.doc, line1, col1)
    end
  end
end

--
-- Commands
--
command.add("core.docview", {
  ["lsp:complete"] = function()
    local doc = core.active_view.doc
    if doc then
      local line1, col1, line2, col2 = doc:get_selection()
      if line1 == line2 and col1 == col2 then
        lsp.request_completion(doc, line1, col1)
      end
    end
  end,
})

command.add("core.docview", {
  ["lsp:goto-definition"] = function()
    local doc = core.active_view.doc
    if doc then
      local line1, col1, line2, col2 = doc:get_selection()
      if line1 == line2 and col1 == col2 then
        lsp.goto_symbol(doc, line1, col1)
      end
    end
  end,
})

command.add("core.docview", {
  ["lsp:goto-implementation"] = function()
    local doc = core.active_view.doc
    if doc then
      local line1, col1, line2, col2 = doc:get_selection()
      if line1 == line2 and col1 == col2 then
        lsp.goto_symbol(doc, line1, col1, true)
      end
    end
  end,
})

--
-- Default Keybindings
--
keymap.add {
  ["ctrl+space"]    = "lsp:complete",
  ["alt+d"]         = "lsp:goto-definition",
  ["alt+shift+d"]   = "lsp:goto-implementation",
}

return lsp
