local Model = require("lapis.db.model").Model
local db = require "lapis.db"
local is_empty = require("pl.types").is_empty
local uuid_generate = require("resty.uuid").generate_random

require "resty.validation.ngx"

local _M = {}

local function values_for_table(model_class, values)
  local column_values = {}
  for _, column in ipairs(model_class:columns()) do
    local name = column["column_name"]
    if values[name] ~= nil then
      column_values[name] = values[name]
    end
  end

  return column_values
end

local function start_transaction()
  -- Only open a new transaction if one isn't already opened.
  --
  -- When dealing with saving nested relationships, this ensures that only the
  -- parent model opens the transaction, and all associated child records are
  -- saved as part of that single transaction (assuming these child records are
  -- saved in the "after_save" callback, which still lives inside the parent's
  -- transaction). This ensures that the parent record save will only be
  -- committed if all child records also save successfully.
  local started = false
  if not ngx.ctx.model_transaction_started then
    db.query("START TRANSACTION")
    started = true
    ngx.ctx.model_transaction_started = true
  end

  return started
end

local function commit_transaction(started)
  -- Only commit the transaction if the current record started the transaction
  -- (see start_transaction).
  if started then
    db.query("COMMIT")
    ngx.ctx.model_transaction_started = false
  end
end

local function before_save(self, action, options, values)
  if action == "create" then
    if not values["id"] then
      values["id"] = uuid_generate()
    end

    if options["before_validate_on_create"] then
      options["before_validate_on_create"](self, values)
    end
  end

  if options["before_validate"] then
    options["before_validate"](self, values)
  end

  if options["validate"] then
    local errors = options["validate"](self, values)
    if not is_empty(errors) then
      return coroutine.yield("error", errors)
    end
  end

  if options["after_validate"] then
    options["after_validate"](self, values)
  end

  if options["before_save"] then
    options["before_save"](self, values)
  end
end

local function after_save(self, _, options, values)
  if options["after_save"] then
    options["after_save"](self, values)
  end
end

function _M.add_error(errors, field, message)
  if not errors[field] then
    errors[field] = {}
  end

  table.insert(errors[field], message)
end

function _M.validate_field(errors, values, field, validator, message, error_field_prefix)
  local value = values[field]
  local ok = validator(value)
  if not ok then
    local error_field = field
    if error_field_prefix then
      error_field = error_field_prefix .. error_field
    end

    _M.add_error(errors, error_field, message)
  end
end

function _M.create(options)
  return function(model_class, values, opts)
    local transaction_started = start_transaction()
    before_save(nil, "create", options, values)

    local new_record = Model.create(model_class, values_for_table(model_class, values), opts)

    after_save(new_record, "create", options, values)
    commit_transaction(transaction_started)

    return new_record
  end
end

function _M.update(options)
  return function(self, values, opts)
    local model_class = self.__class
    local transaction_started = start_transaction()
    before_save(self, "update", options, values)

    local return_value = Model.update(self, values_for_table(model_class, values), opts)

    after_save(self, "update", options, values)
    commit_transaction(transaction_started)

    return return_value
  end
end

local function get_join_records(model_name, options, ids)
  local model = Model:get_relation_model(model_name)
  local join_table = db.escape_identifier(options["join_table"])
  local table_name = db.escape_identifier(model:table_name())
  local primary_key = db.escape_identifier(model.primary_key)
  local foreign_key = db.escape_identifier(options["foreign_key"])
  local association_foreign_key = db.escape_identifier(options["association_foreign_key"])
  local order_by = ""
  if options["order"] then
    order_by = " ORDER BY " .. table_name .. "." .. db.escape_identifier(options["order"])
  end

  local sql = "INNER JOIN " .. join_table .. " ON " .. table_name .. "." .. primary_key .. " = " .. join_table .. "." .. association_foreign_key ..
    " WHERE " .. join_table .. "." .. foreign_key .. " IN ?" ..
    order_by

  local fields = table_name .. ".*, " .. join_table .. "." .. foreign_key .. " AS _foreign_key_id"

  return model:select(sql, db.list(ids), { fields = fields })
end

function _M.has_and_belongs_to_many(name, model_name, options)
  return {
    name,
    fetch = function(self)
      return get_join_records(model_name, options, { self.id })
    end,
    preload = function(primary_records)
      local primary_record_ids = {}
      for _, primary_record in ipairs(primary_records) do
        primary_record[name] = {}
        table.insert(primary_record_ids, primary_record.id)
      end

      if #primary_record_ids > 0 then
        local join_records = get_join_records(model_name, options, primary_record_ids)
        for _, join_record in ipairs(join_records) do
          for _, primary_record in ipairs(primary_records) do
            if primary_record.id == join_record["_foreign_key_id"] then
              table.insert(primary_record[name], join_record)
            end
          end
        end
      end
    end,
  }
end

function _M.save_has_and_belongs_to_many(self, association_foreign_key_ids, options)
  if association_foreign_key_ids then
    local join_table = db.escape_identifier(options["join_table"])
    local foreign_key = db.escape_identifier(options["foreign_key"])
    local association_foreign_key = db.escape_identifier(options["association_foreign_key"])

    for _, association_foreign_key_id in ipairs(association_foreign_key_ids) do
      db.query("INSERT INTO " .. join_table .. "(" .. foreign_key .. ", " .. association_foreign_key .. ") VALUES(?, ?) ON CONFLICT DO NOTHING", self.id, association_foreign_key_id)
    end

    if is_empty(association_foreign_key_ids) then
      db.query("DELETE FROM " .. join_table .. " WHERE " .. foreign_key .. " = ?", self.id)
    else
      db.query("DELETE FROM " .. join_table .. " WHERE " .. foreign_key .. " = ? AND " .. association_foreign_key .. " NOT IN ?", self.id, db.list(association_foreign_key_ids))
    end
  end
end

function _M.new_class(table_name, model_options, save_options)
  model_options.update = _M.update(save_options)
  local model_class = Model:extend(table_name, model_options)
  model_class.create = _M.create(save_options)
  return model_class
end

return _M
