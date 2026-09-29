#!/usr/bin/env ruby
# Build a denylist of identifiers distinctive to a private Rails app, so nothing derived from it leaks
# into public repros or issues: class/module names and longer method names from app/ and lib/,
# plus any extra terms you pass (company, product and vendor names). Generic Rails names are allowed.
# Usage: ruby build_denylist.rb <rails-app-root> [extra terms...] > denylist.txt
root = ARGV.shift or abort "usage: build_denylist.rb <rails-app-root> [extra terms...]"
names = []
Dir[File.join(root, "{app,lib}/**/*.rb")].each do |f|
  File.foreach(f) do |l|
    names << $1.split("::").last if l =~ /^\s*(?:class|module)\s+([A-Z][A-Za-z0-9_:]+)/
    names << $1 if l =~ /^\s*def\s+(?:self\.)?([a-z_][a-z0-9_?!]{11,})/
  end
end
generic = %w[Application ApplicationRecord ApplicationController ApplicationJob ApplicationMailer ApplicationHelper
  Base Error Errors Api V1 V2 External Internal User Users Order Orders Client Clients Company Companies Product
  Products Service Services Search Session Sessions Token Tokens Notification Notifications Connection Helpers Helper
  Views Rails Model Models Record Webhook Webhooks Integration Integrations Address Configuration Brand Tag Tags
  Setting Settings Report Ruby Article Articles Asset Auth Data Emails Enums Import Importer Jobs Location Logger Logs
  Mailing Management Messages Methods Metrics Notifier Pagination Partner Provider Providers Registry Requests Root
  Rule Sandbox Searchable Security Serializer Serializers Site Slack Subscription Sync Tools Tracking Utils Catalog
  Computer Software Finance Department Invoices ErrorsController OrdersController UsersController Widget]
puts((names + ARGV).uniq.sort - generic)
