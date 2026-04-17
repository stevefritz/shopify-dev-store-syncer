email    = ENV["ADMIN_EMAIL"]
password = ENV["ADMIN_PASSWORD"]

if email.blank? || password.blank?
  puts "ADMIN_EMAIL or ADMIN_PASSWORD not set — skipping admin seed."
else
  User.find_or_create_by!(email_address: email) do |user|
    user.password = password
    user.password_confirmation = password
  end
  puts "Admin user ensured: #{email}"
end
