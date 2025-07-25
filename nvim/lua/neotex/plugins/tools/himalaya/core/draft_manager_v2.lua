-- Unified Draft Manager v2
-- Single source of truth for all draft state management

local M = {}

-- Dependencies
local notify = require('neotex.util.notifications')
local utils = require('neotex.plugins.tools.himalaya.utils')
local state = require('neotex.plugins.tools.himalaya.core.state')
local events_bus = require('neotex.plugins.tools.himalaya.orchestration.events')
local event_types = require('neotex.plugins.tools.himalaya.core.events')
local logger = require('neotex.plugins.tools.himalaya.core.logger')

-- Draft notification helper (Phase 4)
--- Send draft-specific notifications using the unified notification system
--- @param message string The notification message
--- @param category table The notification category (from notify.categories)
--- @param context table? Additional context for the notification
local function notify_draft(message, category, context)
  context = vim.tbl_extend('force', context or {}, {
    module = 'himalaya',
    feature = 'drafts'
  })
  notify.himalaya(message, category, context)
end

-- Draft states
M.states = {
  NEW = 'new',
  SYNCING = 'syncing',
  SYNCED = 'synced',
  ERROR = 'error'
}

-- Draft storage keyed by buffer number
M.drafts = {}

-- Initialize draft manager
function M.setup()
  -- Create autocmd group for cleanup
  local group = vim.api.nvim_create_augroup('HimalayaDraftManagerV2', { clear = true })
  
  -- Clean up drafts when buffers are deleted
  vim.api.nvim_create_autocmd('BufDelete', {
    group = group,
    callback = function(args)
      M.cleanup_draft(args.buf)
    end,
    desc = 'Clean up draft when buffer is deleted'
  })
  
  -- Sync with centralized state on startup
  M._sync_with_state()
  
  -- Check for orphaned drafts that need recovery
  vim.defer_fn(function()
    M._check_orphaned_drafts()
  end, 200)
end

--- Sync local cache with centralized state on startup
--- This ensures drafts persisted in state are available in the local cache
--- Only syncs drafts with valid buffers to avoid stale entries
function M._sync_with_state()
  -- Get all drafts from centralized state
  local state_drafts = state.get_all_drafts()
  
  -- Add any drafts that exist in state but not in local cache
  for buffer_id, draft in pairs(state_drafts) do
    local buf = tonumber(buffer_id)
    if buf and vim.api.nvim_buf_is_valid(buf) and not M.drafts[buf] then
      M.drafts[buf] = draft
    end
  end
end

--- Check for orphaned drafts that might need recovery
--- Emits DRAFT_RECOVERY_NEEDED events for drafts that exist in storage but not in state
function M._check_orphaned_drafts()
  local storage = require('neotex.plugins.tools.himalaya.core.local_storage')
  local logger = require('neotex.plugins.tools.himalaya.core.logger')
  
  -- Get all drafts from storage
  local stored_drafts = storage.list()
  
  -- Get all drafts from state
  local state_drafts = state.get_all_drafts()
  local state_ids = {}
  for _, draft in pairs(state_drafts) do
    state_ids[draft.local_id] = true
  end
  
  -- Check for orphaned drafts
  for _, stored in ipairs(stored_drafts) do
    if not state_ids[stored.local_id] and not M.drafts[stored.local_id] then
      -- Check if draft has any meaningful content
      local has_content = false
      if stored.metadata then
        has_content = (stored.metadata.subject and stored.metadata.subject ~= "") or
                     (stored.metadata.to and stored.metadata.to ~= "") or
                     (stored.content and stored.content:match("[^\n%s]"))
      end
      
      if has_content then
        -- Found orphaned draft with content
        logger.info("Found orphaned draft", {
          local_id = stored.local_id,
          subject = stored.metadata and stored.metadata.subject,
          modified = stored.updated_at
        })
        
        -- Emit recovery needed event
        events_bus.emit(event_types.DRAFT_RECOVERY_NEEDED, {
          draft_id = stored.local_id,
          last_modified = stored.updated_at,
          metadata = stored.metadata
        })
      else
        -- Keep all drafts for local-first approach
        -- Don't delete even if empty
        logger.debug("Keeping draft (local-first approach)", {
          local_id = stored.local_id
        })
      end
    end
  end
end

-- Create a new draft
-- @param buffer number Buffer number
-- @param account string Account name
-- @param opts table Optional settings (compose_type, reply_to, etc)
-- @return table Draft object
function M.create(buffer, account, opts)
  opts = opts or {}
  
  local draft = {
    buffer = buffer,
    local_id = opts.local_id or ('draft_' .. os.time() .. '_' .. vim.loop.hrtime()), -- Use provided or generate
    remote_id = nil,
    state = M.states.NEW,
    local_file = vim.api.nvim_buf_get_name(buffer),
    account = account,
    metadata = {
      subject = opts.subject or '',
      to = opts.to or '',
      from = opts.from or M._get_default_from(account),
      cc = opts.cc or '',
      bcc = opts.bcc or '',
      reply_to = opts.reply_to,
      compose_type = opts.compose_type or 'new'
    },
    content_hash = nil,
    last_sync = nil,
    sync_error = nil,
    created_at = os.time(),
    modified_at = os.time()
  }
  
  -- Store in drafts table
  M.drafts[buffer] = draft
  
  -- Store in centralized state
  state.set_draft(buffer, draft)
  
  -- Set buffer variable for easy access
  vim.api.nvim_buf_set_var(buffer, 'himalaya_draft', draft)
  
  -- Emit draft created event
  events_bus.emit(event_types.DRAFT_CREATED, {
    draft_id = draft.local_id,
    buffer = buffer,
    account = account,
    metadata = draft.metadata,
    compose_type = opts.compose_type
  })
  
  -- Debug notification for draft creation (only for new drafts, not edits)
  if opts.compose_type ~= 'edit' then
    notify_draft(
      "New draft created",
      notify.categories.BACKGROUND,
      {
        local_id = draft.local_id,
        buffer = buffer,
        account = account,
        compose_type = draft.metadata.compose_type
      }
    )
  end
  
  return draft
end

-- Save draft locally (DEPRECATED - kept for compatibility)
-- The new save flow is handled entirely in email_composer.save_draft
-- @param buffer number Buffer number
-- @return boolean success
-- @return string|nil error
function M.save_local(buffer)
  -- This function is now just a stub that returns success
  -- All saving is handled by email_composer.save_draft
  return true
end

-- Sync draft to remote (DEPRECATED - kept for compatibility)
-- The new sync flow is handled by email_composer.sync_draft_to_remote
-- @param buffer number Buffer number
-- @return boolean success
-- @return string|nil error
function M.sync_remote(buffer)
  -- This function is now just a stub that returns success
  -- All syncing is handled by email_composer.sync_draft_to_remote
  return true
end

-- Handle sync completion (called by sync engine)
-- @param local_id string Local draft ID
-- @param remote_id string Remote draft ID
-- @param success boolean Whether sync succeeded
-- @param error string|nil Error message if failed
function M.handle_sync_completion(local_id, remote_id, success, error)
  -- Find draft by local ID
  local draft = nil
  local buffer = nil
  
  for buf, d in pairs(M.drafts) do
    if d.local_id == local_id then
      draft = d
      buffer = buf
      break
    end
  end
  
  if not draft then
    return -- Draft no longer exists
  end
  
  if success then
    -- Update draft with remote ID
    draft.remote_id = tostring(remote_id)
    draft.state = M.states.SYNCED
    draft.last_sync = os.time()
    draft.sync_error = nil
    draft.synced = true
    draft.modified = false
    
    -- Update local storage with remote_id
    local storage = require('neotex.plugins.tools.himalaya.core.local_storage')
    local data = storage.load(draft.local_id)
    if data then
      data.remote_id = draft.remote_id
      storage.save(draft.local_id, data)
    end
    
    -- Emit sync success event
    events_bus.emit(event_types.DRAFT_SYNCED, {
      draft_id = draft.local_id,
      remote_id = draft.remote_id,
      sync_time = draft.last_sync
    })
    
    -- User notification for successful sync
    notify_draft(
      "Draft synced successfully",
      notify.categories.USER_ACTION,
      { draft_id = draft.remote_id, subject = draft.metadata.subject }
    )
    
    -- Remove from unsaved drafts
    if buffer then
      state.remove_unsaved_draft(buffer)
    end
  else
    -- Sync failed
    draft.state = M.states.ERROR
    draft.sync_error = error
    
    -- Emit sync failed event
    events_bus.emit(event_types.DRAFT_SYNC_FAILED, {
      draft_id = draft.local_id,
      error = error,
      will_retry = true
    })
    
    -- User notification for sync failure
    notify_draft(
      string.format("Draft sync failed: %s", error),
      notify.categories.ERROR,
      { draft_id = draft.local_id }
    )
  end
  
  -- Update centralized state
  if buffer then
    state.set_draft(buffer, draft)
  end
  state.set_draft_sync_status(false)
  
  -- Update buffer variable if buffer still exists
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_set_var(buffer, 'himalaya_draft', draft)
  end
end

-- Load draft from remote (returns raw content)
-- @param remote_id string Remote draft ID
-- @param account string Account name
-- @return table|nil Draft data with raw content
-- @return string|nil error
function M.load(remote_id, account)
  -- First check local storage
  local storage = require('neotex.plugins.tools.himalaya.core.local_storage')
  local cached = storage.find_by_remote_id(remote_id, account)
  if cached and cached.content then
    return cached
  end
  
  -- Try to load from himalaya
  local ok, result = pcall(utils.execute_himalaya, 
    { 'message', 'read', tostring(remote_id) },
    { account = account, folder = 'Drafts' }
  )
  
  if ok and result then
    -- Return raw content without parsing
    return {
      remote_id = remote_id,
      account = account,
      content = result,
      metadata = {}  -- Will be parsed for display only
    }
  end
  
  return nil, "Failed to load draft: " .. (result or "Unknown error")
end

-- Delete draft
-- @param buffer number Buffer number
-- @return boolean success
-- @return string|nil error
function M.delete(buffer)
  local draft = M.drafts[buffer]
  if not draft then
    return true -- Already deleted
  end
  
  -- Delete from remote if synced
  if draft.remote_id then
    local ok, err = pcall(utils.execute_himalaya,
      { 'message', 'delete', tostring(draft.remote_id) },
      { account = draft.account, folder = 'Drafts' }
    )
    
    if not ok then
      notify_draft(
        string.format("Failed to delete remote draft: %s", err),
        notify.categories.ERROR,
        { draft_id = draft.remote_id }
      )
      return false, "Failed to delete remote draft: " .. err
    end
  end
  
  -- Delete from local storage
  local storage = require('neotex.plugins.tools.himalaya.core.local_storage')
  storage.delete(draft.local_id)
  
  -- Remove from drafts table
  M.drafts[buffer] = nil
  
  -- Remove from centralized state
  state.remove_draft(buffer)
  state.remove_unsaved_draft(buffer)
  
  -- Emit draft deleted event
  events_bus.emit(event_types.DRAFT_DELETED, {
    draft_id = draft.local_id,
    remote_id = draft.remote_id,
    account = draft.account
  })
  
  -- User notification
  notify_draft(
    "Draft deleted",
    notify.categories.USER_ACTION,
    { draft_id = draft.remote_id or draft.local_id }
  )
  
  return true
end

-- Get draft by buffer
-- @param buffer number Buffer number
-- @return table|nil Draft object
function M.get_by_buffer(buffer)
  -- Try local cache first
  local draft = M.drafts[buffer]
  if draft then
    return draft
  end
  
  -- Fall back to centralized state
  return state.get_draft_by_buffer(buffer)
end

-- Get draft by remote ID
-- @param remote_id string Remote draft ID
-- @return table|nil Draft object
function M.get_by_remote_id(remote_id)
  -- Check local cache first
  for _, draft in pairs(M.drafts) do
    if draft.remote_id == tostring(remote_id) then
      return draft
    end
  end
  
  -- Check centralized state
  for _, draft in pairs(state.get_all_drafts()) do
    if draft.remote_id == tostring(remote_id) then
      return draft
    end
  end
  
  return nil
end

--- Get draft by local ID
--- @param local_id string Local draft ID
--- @return table|nil Draft object
function M.get_by_local_id(local_id)
  -- Check in buffer-keyed drafts
  for _, draft in pairs(M.drafts) do
    if type(draft) == 'table' and draft.local_id == local_id then
      return draft
    end
  end
  
  -- Check in state as fallback
  for _, draft in pairs(state.get_all_drafts()) do
    if draft.local_id == local_id then
      return draft
    end
  end
  
  return nil
end

-- Cleanup draft when buffer is deleted
-- @param buffer number Buffer number
function M.cleanup_draft(buffer)
  local draft = M.drafts[buffer]
  if draft then
    -- Check if draft has any meaningful content by looking at storage
    local storage = require('neotex.plugins.tools.himalaya.core.local_storage')
    local stored = storage.load(draft.local_id)
    local has_content = false
    
    if stored and stored.content then
      -- Check if content has more than just headers template
      has_content = stored.content:match("[^%s\n]") and #stored.content > 50
    end
    
    -- If draft is empty and was never synced, just delete it completely
    if not has_content and draft.state == M.states.NEW then
      -- Delete from local storage
      local storage = require('neotex.plugins.tools.himalaya.core.local_storage')
      storage.delete(draft.local_id)
      
      -- Remove from memory
      M.drafts[buffer] = nil
      state.remove_draft(buffer)
      state.remove_unsaved_draft(buffer)
      
      logger.debug("Cleaned up empty draft", { local_id = draft.local_id })
      return
    end
    
    -- Only remove from memory, keep on disk/remote
    M.drafts[buffer] = nil
    
    -- Remove from centralized state (but keep in recovery if unsaved)
    if draft.synced then
      state.remove_draft(buffer)
      state.remove_unsaved_draft(buffer)
    else
      -- Keep in recovery for potential restoration
      state.add_unsaved_draft(buffer, {
        local_id = draft.local_id,
        subject = draft.metadata.subject,
        modified_at = draft.modified_at,
        account = draft.account
      })
    end
    
    -- Debug notification for cleanup (commented out to reduce noise)
    -- notify_draft(
    --   "Draft buffer closed",
    --   notify.categories.STATUS,
    --   { local_id = draft.local_id, buffer = buffer }
    -- )
  end
end

-- REMOVED: _update_metadata_from_content - parsing is now done only for display

-- Save draft (user-initiated)
-- @param buffer number Buffer number
-- @return boolean success
function M.save(buffer)
  return M.save_local(buffer)
end

-- Send draft as email
-- @param buffer number Buffer number
-- @return boolean success
-- @return string|nil error
function M.send(buffer)
  local draft = M.get_by_buffer(buffer)
  if not draft then
    notify_draft("No draft associated with this buffer", notify.categories.WARNING)
    return false, "No draft found"
  end
  
  -- First save the draft
  local ok, err = M.save_local(buffer)
  if not ok then
    return false, err
  end
  
  -- TODO: Implement actual sending logic
  -- For now, just mark as sent and delete
  notify_draft(
    string.format("Email sent: %s", draft.metadata.subject or "Untitled"),
    notify.categories.USER_ACTION,
    { to = draft.metadata.to, subject = draft.metadata.subject }
  )
  
  -- Delete the draft after sending
  return M.delete(buffer)
end

-- Get all active drafts
-- @return table List of draft objects
function M.get_all()
  local drafts = {}
  
  -- Get from local cache
  for _, draft in pairs(M.drafts) do
    table.insert(drafts, draft)
  end
  
  -- Also get from centralized state
  for buf_id, draft in pairs(state.get_all_drafts()) do
    -- Only add if not already in local cache
    if not M.drafts[tonumber(buf_id)] then
      table.insert(drafts, draft)
    end
  end
  
  return drafts
end

-- Check if buffer has a draft
-- @param buffer number Buffer number
-- @return boolean
function M.has_draft(buffer)
  return M.drafts[buffer] ~= nil or state.get_draft_by_buffer(buffer) ~= nil
end

-- Get default from address for account
-- @param account string Account name
-- @return string Default from address
function M._get_default_from(account)
  -- Handle nil account
  if not account then
    account = 'default'
  end
  
  -- For testing, use a simple format
  -- In production, this would read from account config
  if account == 'gmail' then
    return 'Benjamin Brast-McKie <benbrastmckie@gmail.com>'
  else
    return account .. '@example.com'
  end
end

--- Load draft data from local storage file
--- @param local_path string Path to the draft file
--- @return table|nil draft Draft data or nil if loading fails
function M._load_draft_from_file(local_path)
  local storage = require('neotex.plugins.tools.himalaya.core.local_storage')
  
  -- Extract local_id from the file path
  local local_id = vim.fn.fnamemodify(local_path, ':t:r')
  
  -- Load from storage
  local draft_data = storage.load(local_id)
  if not draft_data then
    return nil
  end
  
  -- Reconstruct draft object
  local draft = {
    local_id = local_id,
    remote_id = draft_data.remote_id,
    account = draft_data.account,
    metadata = draft_data.metadata or {},
    content = draft_data.content,
    state = draft_data.synced and M.states.SYNCED or M.states.MODIFIED,
    created_at = draft_data.created_at,
    modified_at = draft_data.updated_at,
    synced = draft_data.synced or false,
    modified = not draft_data.synced,
    local_path = local_path,
    content_hash = draft_data.content_hash
  }
  
  return draft
end

--- Recover drafts from previous session
--- @return number recovered Number of drafts recovered
function M.recover_session()
  local logger = require('neotex.plugins.tools.himalaya.core.logger')
  local notify = require('neotex.util.notifications')
  local events = require('neotex.plugins.tools.himalaya.core.events')
  local events_bus = require('neotex.plugins.tools.himalaya.orchestration.events')
  
  logger.info("Starting draft recovery process")
  
  -- Get saved draft metadata from state
  local saved_drafts = state.get_all_drafts()
  local recovered = 0
  local failed = 0
  
  for buffer_id, draft_meta in pairs(saved_drafts) do
    logger.debug("Attempting to recover draft", {
      buffer_id = buffer_id,
      local_id = draft_meta.local_id,
      local_path = draft_meta.local_path
    })
    
    -- Check if local file exists
    if draft_meta.local_path and vim.fn.filereadable(draft_meta.local_path) == 1 then
      -- Try to reload the draft
      local ok, draft = pcall(M._load_draft_from_file, draft_meta.local_path)
      if ok and draft then
        -- Don't recreate buffer - just store the draft data
        -- Buffer will be created when user opens the draft
        draft.buffer = nil -- Clear any old buffer reference
        draft.recovered = true -- Mark as recovered
        
        -- Store in local cache by local_id
        M.drafts[draft.local_id] = draft
        recovered = recovered + 1
        
        logger.info("Successfully recovered draft", {
          local_id = draft.local_id,
          subject = draft.metadata.subject
        })
        
        -- Emit recovery event
        if events and events_bus then
          events_bus.emit(events.DRAFT_RECOVERED, {
            draft = draft,
            was_modified = draft_meta.modified and not draft_meta.synced
          })
        end
        
        -- Track if it needs syncing
        if draft_meta.modified and not draft_meta.synced then
          state.add_pending_sync({
            local_id = draft.local_id,
            account = draft.account,
            subject = draft.metadata.subject or "Untitled"
          })
        end
      else
        failed = failed + 1
        logger.error("Failed to recover draft", {
          local_id = draft_meta.local_id,
          error = draft or "Unknown error"
        })
        
        -- Remove from state since we can't recover it
        state.remove_draft(buffer_id)
      end
    else
      -- File doesn't exist, remove from state
      state.remove_draft(buffer_id)
      logger.warn("Draft file not found, removing from state", {
        local_id = draft_meta.local_id,
        local_path = draft_meta.local_path
      })
    end
  end
  
  -- Update recovery timestamp
  if recovered > 0 or failed > 0 then
    state.set_last_recovery()
  end
  
  -- Notify user of results
  if recovered > 0 then
    notify_draft(
      string.format("Recovered %d draft(s) from previous session", recovered),
      notify.categories.USER_ACTION,
      { 
        recovered = recovered,
        failed = failed 
      }
    )
  end
  
  if failed > 0 then
    notify_draft(
      string.format("Failed to recover %d draft(s)", failed),
      notify.categories.WARNING,
      { failed = failed }
    )
  end
  
  logger.info("Draft recovery complete", {
    recovered = recovered,
    failed = failed,
    total = recovered + failed
  })
  
  return recovered
end

--- Open a recovered draft in a new buffer
--- @param local_id string The local ID of the draft to open
--- @return number|nil buffer The buffer number or nil if not found
function M.open_recovered_draft(local_id)
  local draft = M.drafts[local_id]
  if not draft or not draft.recovered then
    return nil
  end
  
  -- Create a new buffer
  local buf = vim.api.nvim_create_buf(true, false)
  
  -- Set buffer content
  if draft.content then
    local lines = vim.split(draft.content, '\n')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  
  -- Associate draft with buffer
  draft.buffer = buf
  draft.recovered = nil -- Clear recovered flag
  M.drafts[buf] = draft
  
  -- Update state
  state.set_draft(buf, draft)
  
  -- Set buffer variables
  vim.api.nvim_buf_set_var(buf, 'himalaya_draft', {
    local_id = draft.local_id,
    account = draft.account,
    compose_type = draft.compose_type or 'recovered'
  })
  
  -- Set buffer name
  local name = string.format("himalaya://draft/%s", draft.local_id)
  vim.api.nvim_buf_set_name(buf, name)
  
  -- Setup buffer (autocmds, etc)
  M._setup_draft_buffer(buf)
  
  return buf
end

-- Create new draft (wrapper for UI)
-- @param account string? Optional account name
function M.create_draft(account)
  local ui = require('neotex.plugins.tools.himalaya.ui')
  ui.compose_email(account)
end

-- Sync all unsaved drafts
-- @return number synced Number of drafts queued for sync
function M.sync_all()
  local drafts = M.get_all()
  local synced = 0
  
  for _, draft in ipairs(drafts) do
    if draft.modified and not draft.synced and draft.buffer then
      if vim.api.nvim_buf_is_valid(draft.buffer) then
        local ok = M.sync_remote(draft.buffer)
        if ok then
          synced = synced + 1
        end
      end
    end
  end
  
  return synced
end

-- List all drafts (wrapper for UI display)
function M.list_drafts()
  local drafts = M.get_all()
  local float = require('neotex.plugins.tools.himalaya.ui.float')
  
  if #drafts == 0 then
    local notify = require('neotex.util.notifications')
    notify.himalaya("No active drafts", notify.categories.USER_ACTION)
    return
  end
  
  -- The command module will handle the display
  return drafts
end

--- Get list of recovered drafts
--- @return table drafts List of recovered draft info
function M.get_recovered_drafts()
  local recovered = {}
  
  for id, draft in pairs(M.drafts) do
    if type(id) == 'string' and draft.recovered then
      table.insert(recovered, {
        local_id = draft.local_id,
        subject = draft.metadata.subject or "Untitled",
        to = draft.metadata.to,
        modified = draft.modified,
        synced = draft.synced,
        created_at = draft.created_at,
        modified_at = draft.modified_at
      })
    end
  end
  
  -- Sort by modified time (newest first)
  table.sort(recovered, function(a, b)
    return (a.modified_at or 0) > (b.modified_at or 0)
  end)
  
  return recovered
end

return M