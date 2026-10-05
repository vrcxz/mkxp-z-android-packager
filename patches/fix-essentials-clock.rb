# This Android port exposes System.uptime as integer microseconds.
# Essentials v21 expects floating-point seconds. Leave newer engines alone.
module System
  class << self
    unless method_defined?(:essentials_original_uptime)
      alias_method :essentials_original_uptime, :uptime
      if System.essentials_original_uptime.is_a?(Integer)
        def uptime
          essentials_original_uptime / 1_000_000.0
        end
      end
    end
  end
end
