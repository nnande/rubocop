# frozen_string_literal: true

require 'yaml'
require 'pathname'

module RuboCop
  # A help class for ConfigLoader that handles configuration resolution.
  class ConfigLoaderResolver
    def resolve_requires(path, hash)
      config_dir = File.dirname(path)
      Array(hash.delete('require')).each do |r|
        if r.start_with?('.')
          require(File.join(config_dir, r))
        else
          require(r)
        end
      end
    end

    def resolve_inheritance(path, hash, file)
      base_configs(path, hash['inherit_from'], file)
        .reverse_each do |base_config|
        base_config.each do |k, v|
          hash[k] = hash.key?(k) ? merge(v, hash[k]) : v if v.is_a?(Hash)
        end
      end
    end

    def resolve_inheritance_from_gems(hash, gems)
      (gems || {}).each_pair do |gem_name, config_path|
        if gem_name == 'rubocop'
          raise ArgumentError,
                "can't inherit configuration from the rubocop gem"
        end

        hash['inherit_from'] = Array(hash['inherit_from'])
        Array(config_path).reverse.each do |path|
          # Put gem configuration first so local configuration overrides it.
          hash['inherit_from'].unshift gem_config_path(gem_name, path)
        end
      end
    end

    # Merges the given configuration with the default one. If
    # AllCops:DisabledByDefault is true, it changes the Enabled params so that
    # only cops from user configuration are enabled.  If
    # AllCops::EnabledByDefault is true, it changes the Enabled params so that
    # only cops explicitly disabled in user configuration are disabled.
    def merge_with_default(config, config_file)
      default_configuration = ConfigLoader.default_configuration

      disabled_by_default = config.for_all_cops['DisabledByDefault']
      enabled_by_default = config.for_all_cops['EnabledByDefault']

      if disabled_by_default || enabled_by_default
        default_configuration = transform(default_configuration) do |params|
          params.merge('Enabled' => !disabled_by_default)
        end
      end

      if disabled_by_default
        config = handle_disabled_by_default(config, default_configuration)
      end

      Config.new(merge(default_configuration, config), config_file)
    end

    # Returns a new hash where the parameters of the given config hash have
    # been replaced by parameters returned by the given block.
    # Return a recursive merge of two hashes. That is, a normal hash merge,
    # with the addition that any value that is a hash, and occurs in both
    # arguments, will also be merged. And so on.
    def merge(base_hash, derived_hash)
      result = base_hash.merge(derived_hash)
      keys_appearing_in_both = base_hash.keys & derived_hash.keys
      keys_appearing_in_both.each do |key|
        next unless base_hash[key].is_a?(Hash)
        result[key] = merge(base_hash[key], derived_hash[key])
      end
      result
    end

    private

    def base_configs(path, inherit_from, file)
      configs = Array(inherit_from).compact.map do |f|
        ConfigLoader.load_file(inherited_file(path, f, file))
      end

      configs.compact
    end

    def inherited_file(path, inherit_from, file)
      regex = URI::DEFAULT_PARSER.make_regexp(%w[http https])
      if inherit_from =~ /\A#{regex}\z/
        RemoteConfig.new(inherit_from, File.dirname(path))
      elsif file.is_a?(RemoteConfig)
        file.inherit_from_remote(inherit_from, path)
      else
        print 'Inheriting ' if ConfigLoader.debug?
        File.expand_path(inherit_from, File.dirname(path))
      end
    end

    def handle_disabled_by_default(config, new_default_configuration)
      department_config = config.to_hash.reject { |cop| cop.include?('/') }
      department_config.each do |dept, dept_params|
        # Rails is always disabled by default and the department's Enabled flag
        # works like the --rails command line option, which is that when
        # AllCops:DisabledByDefault is true, each Rails cop must still be
        # explicitly mentioned in user configuration in order to be enabled.
        next if dept == 'Rails'

        next unless dept_params['Enabled']

        new_default_configuration.each do |cop, params|
          next unless cop.start_with?(dept + '/')

          # Retain original default configuration for cops in the department.
          params['Enabled'] = ConfigLoader.default_configuration[cop]['Enabled']
        end
      end

      transform(config) do |params|
        { 'Enabled' => true }.merge(params) # Set true if not set.
      end
    end

    def transform(config)
      Hash[config.map { |cop, params| [cop, yield(params)] }]
    end

    def gem_config_path(gem_name, relative_config_path)
      spec = Gem::Specification.find_by_name(gem_name)
      return File.join(spec.gem_dir, relative_config_path)
    rescue Gem::LoadError => e
      raise Gem::LoadError,
            "Unable to find gem #{gem_name}; is the gem installed? #{e}"
    end
  end
end
