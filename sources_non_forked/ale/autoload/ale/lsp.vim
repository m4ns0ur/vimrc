" Author: w0rp <devw0rp@gmail.com>
" Description: Language Server Protocol client code

" A Dictionary for tracking connections.
let s:connections = get(s:, 'connections', {})
let g:ale_lsp_next_message_id = 1

" Given an id, which can be an executable or address, a project path,
" and a language string or (bufnr) -> string function
" create a new connection if needed. Return a unique ID for the connection.
function! ale#lsp#Register(executable_or_address, project, language, init_options) abort
    let l:conn_id = a:executable_or_address . ':' . a:project

    if !has_key(s:connections, l:conn_id)
        " is_tsserver: 1 if the connection is for tsserver.
        " data: The message data received so far.
        " root: The project root.
        " open_documents: A Dictionary mapping buffers to b:changedtick, keeping
        "   track of when documents were opened, and when we last changed them.
        " initialized: 0 if the connection is ready, 1 otherwise.
        " init_request_id: The ID for the init request.
        " init_options: Options to send to the server.
        " config: Configuration settings to send to the server.
        " callback_list: A list of callbacks for handling LSP responses.
        " capabilities_queue: The list of callbacks to call with capabilities.
        " capabilities: Features the server supports.
        let s:connections[l:conn_id] = {
        \   'id': l:conn_id,
        \   'is_tsserver': 0,
        \   'data': '',
        \   'root': a:project,
        \   'language': a:language,
        \   'open_documents': {},
        \   'initialized': 0,
        \   'init_request_id': 0,
        \   'init_options': a:init_options,
        \   'config': {},
        \   'callback_list': [],
        \   'init_queue': [],
        \   'capabilities': {
        \       'hover': 0,
        \       'rename': 0,
        \       'filerename': 0,
        \       'references': 0,
        \       'completion': 0,
        \       'completion_trigger_characters': [],
        \       'definition': 0,
        \       'typeDefinition': 0,
        \       'implementation': 0,
        \       'pull_model': 0,
        \       'symbol_search': 0,
        \       'code_actions': 0,
        \       'did_save': 0,
        \       'includeText': 0,
        \   },
        \}
    endif

    return l:conn_id
endfunction

" Remove an LSP connection with a given ID. This is only for tests.
function! ale#lsp#RemoveConnectionWithID(id) abort
    if has_key(s:connections, a:id)
        call remove(s:connections, a:id)
    endif
endfunction

function! ale#lsp#ResetConnections() abort
    let s:connections = {}
endfunction

" Used only in tests.
function! ale#lsp#GetConnections() abort
    " This command will throw from the sandbox.
    let &l:equalprg=&l:equalprg

    return s:connections
endfunction

" This is only needed for tests
function! ale#lsp#MarkDocumentAsOpen(id, buffer) abort
    let l:conn = get(s:connections, a:id, {})

    if !empty(l:conn)
        let l:conn.open_documents[a:buffer] = -1
    endif
endfunction

function! ale#lsp#GetNextMessageID() abort
    " Use the current ID
    let l:id = g:ale_lsp_next_message_id

    " Increment the ID variable.
    let g:ale_lsp_next_message_id += 1

    " When the ID overflows, reset it to 1. By the time we hit the initial ID
    " again, the messages will be long gone.
    if g:ale_lsp_next_message_id < 1
        let g:ale_lsp_next_message_id = 1
    endif

    return l:id
endfunction

" TypeScript messages use a different format.
function! s:CreateTSServerMessageData(message) abort
    let l:is_notification = a:message[0]

    let l:obj = {
    \   'seq': v:null,
    \   'type': 'request',
    \   'command': a:message[1][3:],
    \}

    if !l:is_notification
        let l:obj.seq = ale#lsp#GetNextMessageID()
    endif

    if len(a:message) > 2
        let l:obj.arguments = a:message[2]
    endif

    let l:data = json_encode(l:obj) . "\n"

    return [l:is_notification ? 0 : l:obj.seq, l:data]
endfunction

" Given a List of one or two items, [method_name] or [method_name, params],
" return a List containing [message_id, message_data]
function! ale#lsp#CreateMessageData(message) abort
    if a:message[1][:2] is# 'ts@'
        return s:CreateTSServerMessageData(a:message)
    endif

    let l:is_notification = a:message[0]

    let l:obj = {
    \   'method': a:message[1],
    \   'jsonrpc': '2.0',
    \}

    if !l:is_notification
        let l:obj.id = ale#lsp#GetNextMessageID()
    endif

    if len(a:message) > 2
        let l:obj.params = a:message[2]
    endif

    let l:body = json_encode(l:obj)
    let l:data = 'Content-Length: ' . strlen(l:body) . "\r\n\r\n" . l:body

    return [l:is_notification ? 0 : l:obj.id, l:data]
endfunction

function! ale#lsp#ReadMessageData(data) abort
    let l:response_list = []
    let l:remainder = a:data

    while 1
        " Look for the end of the HTTP headers
        let l:body_start_index = matchend(l:remainder, "\r\n\r\n")

        if l:body_start_index < 0
            " No header end was found yet.
            break
        endif

        " Parse the Content-Length header.
        let l:header_data = l:remainder[:l:body_start_index - 4]
        let l:length_match = matchlist(
        \   l:header_data,
        \   '\vContent-Length: *(\d+)'
        \)

        if empty(l:length_match)
            throw "Invalid JSON-RPC header:\n" . l:header_data
        endif

        " Split the body and the remainder of the text.
        let l:remainder_start_index = l:body_start_index + str2nr(l:length_match[1])

        if len(l:remainder) < l:remainder_start_index
            " We don't have enough data yet.
            break
        endif

        let l:body = l:remainder[l:body_start_index : l:remainder_start_index - 1]
        let l:remainder = l:remainder[l:remainder_start_index :]

        " Parse the JSON object and add it to the list.
        call add(l:response_list, json_decode(l:body))
    endwhile

    return [l:remainder, l:response_list]
endfunction

" Update capabilities from the server, so we know which features the server
" supports.
function! ale#lsp#UpdateCapabilities(conn_id, capabilities) abort
    let l:conn = get(s:connections, a:conn_id, {})

    if empty(l:conn)
        return
    endif

    if type(a:capabilities) isnot v:t_dict
        return
    endif

    if get(a:capabilities, 'hoverProvider') is v:true
        let l:conn.capabilities.hover = 1
    endif

    if type(get(a:capabilities, 'hoverProvider')) is v:t_dict
        let l:conn.capabilities.hover = 1
    endif

    if get(a:capabilities, 'referencesProvider') is v:true
        let l:conn.capabilities.references = 1
    endif

    if type(get(a:capabilities, 'referencesProvider')) is v:t_dict
        let l:conn.capabilities.references = 1
    endif

    if get(a:capabilities, 'renameProvider') is v:true
        let l:conn.capabilities.rename = 1
    endif

    if type(get(a:capabilities, 'renameProvider')) is v:t_dict
        let l:conn.capabilities.rename = 1
    endif

    if get(a:capabilities, 'codeActionProvider') is v:true
        let l:conn.capabilities.code_actions = 1
    endif

    if type(get(a:capabilities, 'codeActionProvider')) is v:t_dict
        let l:conn.capabilities.code_actions = 1
    endif

    if !empty(get(a:capabilities, 'completionProvider'))
        let l:conn.capabilities.completion = 1
    endif

    if type(get(a:capabilities, 'completionProvider')) is v:t_dict
        let l:chars = get(a:capabilities.completionProvider, 'triggerCharacters')

        if type(l:chars) is v:t_list
            let l:conn.capabilities.completion_trigger_characters = l:chars
        endif
    endif

    if get(a:capabilities, 'definitionProvider') is v:true
        let l:conn.capabilities.definition = 1
    endif

    if type(get(a:capabilities, 'definitionProvider')) is v:t_dict
        let l:conn.capabilities.definition = 1
    endif

    if get(a:capabilities, 'typeDefinitionProvider') is v:true
        let l:conn.capabilities.typeDefinition = 1
    endif

    if type(get(a:capabilities, 'typeDefinitionProvider')) is v:t_dict
        let l:conn.capabilities.typeDefinition = 1
    endif

    if get(a:capabilities, 'implementationProvider') is v:true
        let l:conn.capabilities.implementation = 1
    endif

    if type(get(a:capabilities, 'implementationProvider')) is v:t_dict
        let l:conn.capabilities.implementation = 1
    endif

    " Check if the language server supports pull model diagnostics.
    if type(get(a:capabilities, 'diagnosticProvider')) is v:t_dict
        if type(get(a:capabilities.diagnosticProvider, 'interFileDependencies')) is v:t_bool
            let l:conn.capabilities.pull_model = 1
        endif
    endif

    if get(a:capabilities, 'workspaceSymbolProvider') is v:true
        let l:conn.capabilities.symbol_search = 1
    endif

    if type(get(a:capabilities, 'workspaceSymbolProvider')) is v:t_dict
        let l:conn.capabilities.symbol_search = 1
    endif

    if type(get(a:capabilities, 'textDocumentSync')) is v:t_dict
        let l:syncOptions = get(a:capabilities, 'textDocumentSync')

        if get(l:syncOptions, 'save') is v:true
            let l:conn.capabilities.did_save = 1
        endif

        if type(get(l:syncOptions, 'save')) is v:t_dict
            let l:conn.capabilities.did_save = 1

            let l:saveOptions = get(l:syncOptions, 'save')

            if get(l:saveOptions, 'includeText') is v:true
                let l:conn.capabilities.includeText = 1
            endif
        endif
    endif
endfunction

" Update a connection's configuration dictionary and notify LSP servers
" of any changes since the last update. Returns 1 if a configuration
" update was sent; otherwise 0 will be returned.
function! ale#lsp#UpdateConfig(conn_id, buffer, config) abort
    let l:conn = get(s:connections, a:conn_id, {})

    if empty(l:conn) || a:config ==# l:conn.config " no-custom-checks
        return 0
    endif

    let l:conn.config = a:config
    let l:message = ale#lsp#message#DidChangeConfiguration(a:buffer, a:config)

    call ale#lsp#Send(a:conn_id, l:message)

    return 1
endfunction

function! ale#lsp#CallInitCallbacks(conn_id) abort
    let l:conn = get(s:connections, a:conn_id, {})

    if !empty(l:conn)
        " Ensure the connection is marked as initialized.
        " For integration with Neovim's LSP tooling this ensures immediately
        " call OnInit functions in Vim after the `on_init` callback is called.
        let l:conn.initialized = 1

        " Call capabilities callbacks queued for the project.
        for l:Callback in l:conn.init_queue
            call l:Callback()
        endfor

        let l:conn.init_queue = []
    endif
endfunction

function! ale#lsp#HandleInitResponse(conn, response) abort
    if get(a:response, 'method', '') is# 'initialize'
        let a:conn.initialized = 1
    elseif type(get(a:response, 'result')) is v:t_dict
    \&& has_key(a:response.result, 'capabilities')
        call ale#lsp#UpdateCapabilities(a:conn.id, a:response.result.capabilities)

        let a:conn.initialized = 1
    endif

    if !a:conn.initialized
        return
    endif

    " The initialized message must be sent before everything else.
    call ale#lsp#Send(a:conn.id, ale#lsp#message#Initialized())

    call ale#lsp#CallInitCallbacks(a:conn.id)
endfunction

function! ale#lsp#HandleMessage(conn_id, message) abort
    let l:conn = get(s:connections, a:conn_id, {})

    if empty(l:conn)
        return
    endif

    if type(a:message) isnot v:t_string
        " Ignore messages that aren't strings.
        return
    endif

    let l:conn.data .= a:message

    " Parse the objects now if we can, and keep the remaining text.
    let [l:conn.data, l:response_list] = ale#lsp#ReadMessageData(l:conn.data)

    " Look for initialize responses first.
    if !l:conn.initialized
        for l:response in l:response_list
            call ale#lsp#HandleInitResponse(l:conn, l:response)
        endfor
    endif

    " If the connection is marked as initialized, call the callbacks with the
    " responses.
    if l:conn.initialized
        for l:response in l:response_list
            " Call all of the registered handlers with the response.
            for l:Callback in l:conn.callback_list
                call ale#util#GetFunction(l:Callback)(a:conn_id, l:response)
            endfor
        endfor
    endif
endfunction

" Handle a JSON response from a language server.
" This is called from Lua for integration with Neovim's LSP API.
function! ale#lsp#HandleResponse(conn_id, response) abort
    let l:conn = get(s:connections, a:conn_id, {})

    if empty(l:conn)
        return
    endif

    for l:Callback in l:conn.callback_list
        call ale#util#GetFunction(l:Callback)(a:conn_id, a:response)
    endfor
endfunction

" Given a connection ID, mark it as a tsserver connection, so it will be
" handled that way.
function! ale#lsp#MarkConnectionAsTsserver(conn_id) abort
    let l:conn = s:connections[a:conn_id]
    let l:conn.is_tsserver = 1
    let l:conn.initialized = 1
    " Set capabilities which are supported by tsserver.
    let l:conn.capabilities.hover = 1
    let l:conn.capabilities.references = 1
    let l:conn.capabilities.completion = 1
    let l:conn.capabilities.completion_trigger_characters = ['.']
    let l:conn.capabilities.definition = 1
    let l:conn.capabilities.typeDefinition = 1
    let l:conn.capabilities.implementation = 1
    let l:conn.capabilities.symbol_search = 1
    let l:conn.capabilities.rename = 1
    let l:conn.capabilities.filerename = 1
    let l:conn.capabilities.code_actions = 1
endfunction

function! s:SendInitMessage(conn) abort
    let [l:init_id, l:init_data] = ale#lsp#CreateMessageData(
    \   ale#lsp#message#Initialize(
    \       a:conn.root,
    \       a:conn.init_options,
    \       {
    \           'workspace': {
    \               'applyEdit': v:false,
    \               'didChangeConfiguration': {
    \                   'dynamicRegistration': v:false,
    \               },
    \               'symbol': {
    \                   'dynamicRegistration': v:false,
    \               },
    \               'workspaceFolders': v:false,
    \               'configuration': v:false,
    \           },
    \           'textDocument': {
    \               'synchronization': {
    \                   'dynamicRegistration': v:false,
    \                   'willSave': v:false,
    \                   'willSaveWaitUntil': v:false,
    \                   'didSave': v:true,
    \               },
    \               'completion': {
    \                   'dynamicRegistration': v:false,
    \                   'completionItem': {
    \                       'snippetSupport': v:false,
    \                       'commitCharactersSupport': v:false,
    \                       'documentationFormat': ['plaintext', 'markdown'],
    \                       'deprecatedSupport': v:false,
    \                       'preselectSupport': v:false,
    \                   },
    \                   'contextSupport': v:false,
    \               },
    \               'hover': {
    \                   'dynamicRegistration': v:false,
    \                   'contentFormat': ['plaintext', 'markdown'],
    \               },
    \               'references': {
    \                   'dynamicRegistration': v:false,
    \               },
    \               'documentSymbol': {
    \                   'dynamicRegistration': v:false,
    \                   'hierarchicalDocumentSymbolSupport': v:false,
    \               },
    \               'definition': {
    \                   'dynamicRegistration': v:false,
    \                   'linkSupport': v:false,
    \               },
    \               'typeDefinition': {
    \                   'dynamicRegistration': v:false,
    \               },
    \               'implementation': {
    \                   'dynamicRegistration': v:false,
    \                   'linkSupport': v:false,
    \               },
    \               'diagnostic': {
    \                   'dynamicRegistration': v:true,
    \                   'relatedDocumentSupport': v:true,
    \               },
    \               'publishDiagnostics': {
    \                   'relatedInformation': v:true,
    \               },
    \               'codeAction': {
    \                   'dynamicRegistration': v:false,
    \                   'codeActionLiteralSupport': {
    \                        'codeActionKind': {
    \                            'valueSet': []
    \                        }
    \                    }
    \               },
    \               'rename': {
    \                   'dynamicRegistration': v:false,
    \               },
    \           },
    \       },
    \   ),
    \)
    let a:conn.init_request_id = l:init_id
    call s:SendMessageData(a:conn, l:init_data)
endfunction

" Start a program for LSP servers.
"
" 1 will be returned if the program is running, or 0 if the program could
" not be started.
function! ale#lsp#StartProgram(conn_id, executable, command) abort
    let l:conn = s:connections[a:conn_id]
    let l:started = 0

    if g:ale_use_neovim_lsp_api && !l:conn.is_tsserver
        " For Windows from 'cmd /s/c "foo bar"' we need 'foo bar'
        let l:lsp_cmd = has('win32') && type(a:command) is v:t_string
        \   ? ['cmd', '/s/c/', a:command[10:-2]]
        \   : a:command

        " Always call lsp.start, which will either create or re-use a
        " connection. We'll set `attach` to `false` so we can later use
        " our OpenDocument function to attach the buffer separately.
        let l:client_id = luaeval('require("ale.lsp").start(_A)', {
        \   'name': a:conn_id,
        \   'cmd': l:lsp_cmd,
        \   'root_dir': l:conn.root,
        \   'init_options': l:conn.init_options,
        \})

        if l:client_id > 0
            let l:conn.client_id = l:client_id
        endif

        return l:client_id > 0
    endif

    if !has_key(l:conn, 'job_id') || !ale#job#HasOpenChannel(l:conn.job_id)
        let l:options = {
        \   'mode': 'raw',
        \   'out_cb': {_, message -> ale#lsp#HandleMessage(a:conn_id, message)},
        \   'exit_cb': { -> ale#lsp#Stop(a:conn_id) },
        \}

        if has('win32')
            let l:job_id = ale#job#StartWithCmd(a:command, l:options)
        else
            let l:job_id = ale#job#Start(a:command, l:options)
        endif

        let l:started = 1
    else
        let l:job_id = l:conn.job_id
    endif

    if l:job_id > 0
        let l:conn.job_id = l:job_id
    endif

    if l:started && !l:conn.is_tsserver
        let l:conn.initialized = 0
        call s:SendInitMessage(l:conn)
    endif

    return l:job_id > 0
endfunction

" Split an address into [host, port].
" The port will either be a number or v:null.
function! ale#lsp#SplitAddress(address) abort
    let l:port_match = matchlist(a:address, '\v:(\d+)$')

    if !empty(l:port_match)
        let l:host = a:address[:-len(l:port_match[1]) - 2]
        let l:port = l:port_match[1] + 0

        return [l:host, l:port ? l:port : v:null]
    endif

    return [a:address, v:null]
endfunction

" Connect to an LSP server via TCP.
"
" 1 will be returned if the connection is running, or 0 if the connection could
" not be opened.
function! ale#lsp#ConnectToAddress(conn_id, address) abort
    let l:conn = s:connections[a:conn_id]
    let l:started = 0

    if g:ale_use_neovim_lsp_api && !l:conn.is_tsserver
        let [l:host, l:port] = ale#lsp#SplitAddress(a:address)

        let l:client_id = luaeval('require("ale.lsp").start(_A)', {
        \   'name': a:conn_id,
        \   'host': l:host,
        \   'port': l:port,
        \   'root_dir': l:conn.root,
        \   'init_options': l:conn.init_options,
        \})

        if l:client_id > 0
            let l:conn.client_id = l:client_id
        endif

        return l:client_id > 0
    elseif !has_key(l:conn, 'channel_id') || !ale#socket#IsOpen(l:conn.channel_id)
        let l:channel_id = ale#socket#Open(a:address, {
        \   'callback': {_, mess -> ale#lsp#HandleMessage(a:conn_id, mess)},
        \})

        let l:started = 1
    else
        let l:channel_id = l:conn.channel_id
    endif

    if l:channel_id >= 0
        let l:conn.channel_id = l:channel_id
    endif

    if l:started
        call s:SendInitMessage(l:conn)
    endif

    return l:channel_id >= 0
endfunction

" Given a connection ID and a callback, register that callback for handling
" messages if the connection exists.
function! ale#lsp#RegisterCallback(conn_id, callback) abort
    let l:conn = get(s:connections, a:conn_id, {})

    if !empty(l:conn)
        " Add the callback to the List if it's not there already.
        call uniq(sort(add(l:conn.callback_list, a:callback)))
    endif
endfunction

" Stop a single LSP connection.
function! ale#lsp#Stop(conn_id) abort
    if has_key(s:connections, a:conn_id)
        let l:conn = remove(s:connections, a:conn_id)

        if has_key(l:conn, 'channel_id')
            call ale#socket#Close(l:conn.channel_id)
        elseif has_key(l:conn, 'job_id')
            call ale#job#Stop(l:conn.job_id)
        endif
    endif
endfunction

function! ale#lsp#CloseDocument(conn_id) abort
endfunction

" Stop all LSP connections, closing all jobs and channels, and removing any
" queued messages.
function! ale#lsp#StopAll() abort
    for l:conn_id in keys(s:connections)
        call ale#lsp#Stop(l:conn_id)
    endfor
endfunction

function! s:SendMessageData(conn, data) abort
    if has_key(a:conn, 'job_id')
        call ale#job#SendRaw(a:conn.job_id, a:data)
    elseif has_key(a:conn, 'channel_id') && ale#socket#IsOpen(a:conn.channel_id)
        " Send the message to the server
        call ale#socket#Send(a:conn.channel_id, a:data)
    else
        return 0
    endif

    return 1
endfunction

" Send a message to an LSP server.
" Notifications do not need to be handled.
"
" Returns -1 when a message is sent, but no response is expected
"          0 when the message is not sent and
"          >= 1 with the message ID when a response is expected.
function! ale#lsp#Send(conn_id, message) abort
    let l:conn = get(s:connections, a:conn_id, {})

    if empty(l:conn)
        return 0
    endif

    if !l:conn.initialized
        throw 'LSP server not initialized yet!'
    endif

    if g:ale_use_neovim_lsp_api
        return luaeval('require("ale.lsp").send_message(_A)', {
        \   'client_id': l:conn.client_id,
        \   'is_notification': a:message[0] == 1 ? v:true : v:false,
        \   'method': a:message[1],
        \   'params': get(a:message, 2, v:null)
        \})
    endif

    let [l:id, l:data] = ale#lsp#CreateMessageData(a:message)
    call s:SendMessageData(l:conn, l:data)

    return l:id == 0 ? -1 : l:id
endfunction

function! ale#lsp#GetLanguage(conn_id, buffer) abort
    let l:conn = get(s:connections, a:conn_id, {})
    let l:Language = get(l:conn, 'language')

    if empty(l:Language)
        return getbufvar(a:buffer, '&filetype')
    endif

    return type(l:Language) is v:t_func ? l:Language(a:buffer) : l:Language
endfunction

" Notify LSP servers or tsserver if a document is opened, if needed.
" If a document is opened, 1 will be returned, otherwise 0 will be returned.
function! ale#lsp#OpenDocument(conn_id, buffer) abort
    let l:conn = get(s:connections, a:conn_id, {})
    let l:opened = 0

    if !empty(l:conn) && !has_key(l:conn.open_documents, a:buffer)
        if l:conn.is_tsserver
            let l:message = ale#lsp#tsserver_message#Open(a:buffer)
            call ale#lsp#Send(a:conn_id, l:message)
        elseif g:ale_use_neovim_lsp_api
            call luaeval('require("ale.lsp").buf_attach(_A)', {
            \    'bufnr': a:buffer,
            \    'client_id': l:conn.client_id,
            \})
        else
            let l:language_id = ale#lsp#GetLanguage(a:conn_id, a:buffer)
            let l:message = ale#lsp#message#DidOpen(a:buffer, l:language_id)
            call ale#lsp#Send(a:conn_id, l:message)
        endif

        let l:conn.open_documents[a:buffer] = getbufvar(a:buffer, 'changedtick')
        let l:opened = 1
    endif

    return l:opened
endfunction

" Notify LSP servers or tsserver that a document is closed, if opened before.
" If a document is closed, 1 will be returned, otherwise 0 will be returned.
"
" Only the buffer number is required here. A message will be sent to every
" language server that was notified previously of the document being opened.
function! ale#lsp#CloseDocument(buffer) abort
    let l:closed = 0

    " The connection keys are sorted so the messages are easier to test, and
    " so messages are sent in a consistent order.
    for l:conn_id in sort(keys(s:connections))
        let l:conn = s:connections[l:conn_id]

        if l:conn.initialized && has_key(l:conn.open_documents, a:buffer)
            if l:conn.is_tsserver
                let l:message = ale#lsp#tsserver_message#Close(a:buffer)
                call ale#lsp#Send(l:conn_id, l:message)
            elseif g:ale_use_neovim_lsp_api
                call luaeval('require("ale.lsp").buf_detach(_A)', {
                \    'bufnr': a:buffer,
                \    'client_id': l:conn.client_id,
                \})
            else
                let l:message = ale#lsp#message#DidClose(a:buffer)
                call ale#lsp#Send(l:conn_id, l:message)
            endif

            call remove(l:conn.open_documents, a:buffer)
            let l:closed = 1
        endif
    endfor

    return l:closed
endfunction

" Notify LSP servers or tsserver that a document has changed, if needed.
" If a notification is sent, 1 will be returned, otherwise 0 will be returned.
function! ale#lsp#NotifyForChanges(conn_id, buffer) abort
    let l:conn = get(s:connections, a:conn_id, {})
    let l:notified = 0

    if !empty(l:conn) && has_key(l:conn.open_documents, a:buffer)
        let l:new_tick = getbufvar(a:buffer, 'changedtick')

        if l:conn.open_documents[a:buffer] < l:new_tick
            if l:conn.is_tsserver
                let l:message = ale#lsp#tsserver_message#Change(a:buffer)
            else
                let l:message = ale#lsp#message#DidChange(a:buffer)
            endif

            call ale#lsp#Send(a:conn_id, l:message)
            let l:conn.open_documents[a:buffer] = l:new_tick
            let l:notified = 1
        endif
    endif

    return l:notified
endfunction

" Wait for an LSP server to be initialized.
function! ale#lsp#OnInit(conn_id, Callback) abort
    let l:conn = get(s:connections, a:conn_id, {})

    if empty(l:conn)
        return
    endif

    if l:conn.initialized
        call a:Callback()
    else
        call add(l:conn.init_queue, a:Callback)
    endif
endfunction

" Check if an LSP has a given capability.
function! ale#lsp#HasCapability(conn_id, capability) abort
    let l:conn = get(s:connections, a:conn_id, {})

    if empty(l:conn)
        return 0
    endif

    if type(get(l:conn.capabilities, a:capability, v:null)) isnot v:t_number
        throw 'Invalid capability ' . a:capability
    endif

    return l:conn.capabilities[a:capability]
endfunction
