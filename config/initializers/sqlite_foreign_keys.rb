ActiveSupport.on_load(:active_record) do
  if connection.adapter_name.downcase.include?("sqlite")
    connection.execute("PRAGMA foreign_keys = ON")
  end
end
