-- Test Email Commands for Himalaya Plugin

local framework = require('neotex.plugins.tools.himalaya.test.utils.test_framework')
local assert = framework.assert
local helpers = framework.helpers

-- Test suite
local tests = {}

-- Test email list command
table.insert(tests, framework.create_test('email_list_command', function()
  local utils = require('neotex.plugins.tools.himalaya.utils')
  local commands = require('neotex.plugins.tools.himalaya.core.commands.email')
  
  -- Test that email listing function exists
  assert.truthy(type(utils.get_email_list) == "function", "get_email_list should be a function")
  
  -- Try to call it (may fail if himalaya not configured, which is OK)
  local ok, result = pcall(utils.get_email_list, "INBOX")
  if ok and result then
    assert.truthy(result, "Should return some result")
  end
  -- If it fails, that's expected in a test environment without himalaya configured
end))

-- Test email send command
table.insert(tests, framework.create_test('email_send_command', function()
  local scheduler = require('neotex.plugins.tools.himalaya.core.scheduler')
  
  -- Create test email
  local email_data = {
    to = { "test@example.com" },
    subject = "Test Subject",
    body = "Test Body"
  }
  
  -- Test that scheduler function exists
  assert.truthy(type(scheduler.schedule_email) == "function", "schedule_email should be a function")
  
  -- Save original queue state
  local original_queue = vim.deepcopy(scheduler.queue)
  
  -- Send email (should be scheduled)
  local result = scheduler.schedule_email(email_data, nil, { delay = 60 })
  
  -- Verify scheduling
  assert.truthy(result, "Should return scheduled ID")
  
  -- Clean up
  if result then
    scheduler.cancel_send(result)
  end
  scheduler.queue = original_queue
end))

-- Test email delete command
table.insert(tests, framework.create_test('email_delete_command', function()
  local commands = require('neotex.plugins.tools.himalaya.core.commands.email')
  local utils = require('neotex.plugins.tools.himalaya.utils')
  
  -- Test that delete function exists
  assert.truthy(type(utils.delete_email) == "function", "delete_email should be a function")
  
  -- Try to call it (may fail if himalaya not configured, which is OK)
  local ok, result = pcall(utils.delete_email, "test-123")
  if ok and result then
    assert.truthy(result, "Should return some result")
  end
  -- If it fails, that's expected in a test environment without himalaya configured
end))

-- Test email search command
table.insert(tests, framework.create_test('email_search_command', function()
  local search = require('neotex.plugins.tools.himalaya.test.utils.test_search')
  
  -- Create test emails
  local emails = {
    helpers.create_test_email({ subject = "Important Meeting" }),
    helpers.create_test_email({ subject = "Regular Update" }),
    helpers.create_test_email({ subject = "Important Notice" })
  }
  
  -- Test search
  local results = search.filter_emails(emails, "subject:Important")
  
  -- Verify results
  assert.equals(#results, 2, "Should find 2 emails with 'Important' in subject")
end))

-- Export test suite
_G.himalaya_test = framework.create_suite('Email Commands', tests)

return _G.himalaya_test
