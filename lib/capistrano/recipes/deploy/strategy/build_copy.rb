require 'capistrano/recipes/deploy/strategy/base'
require 'fileutils'
require 'tempfile'  # Dir.tmpdir
require 'find'

module Capistrano
  module Deploy
    module Strategy

      class BuildCopy < Base
        def deploy!
          logger.debug("start build strategy #{copy_cache}")
          if copy_cache
            if File.exists?(copy_cache)
              logger.debug "refreshing local cache to revision #{revision} at #{copy_cache}"
              system(source.sync(revision, copy_cache))
            else
              logger.debug "preparing local cache at #{copy_cache}"
              system(source.checkout(revision, copy_cache))
            end
            
            logger.debug "copying cache to deployment staging area #{destination}"
            Dir.chdir(copy_cache) do
              FileUtils.mkdir_p(destination)
              queue = Dir.glob("*", File::FNM_DOTMATCH)
              while queue.any?
                item = queue.shift
                name = File.basename(item)

                next if name == "." || name == ".."
                next if copy_exclude.any? { |pattern| File.fnmatch(pattern, item) }

                if File.directory?(item)
                  queue += Dir.glob("#{item}/*", File::FNM_DOTMATCH)
                  FileUtils.mkdir(File.join(destination, item))
                else
                  FileUtils.ln(File.join(copy_cache, item), File.join(destination, item))
                end
              end
            end
          else
            logger.debug "getting (via #{copy_strategy}) revision #{revision} to #{destination}"
            system(command)

            if copy_exclude.any?
              logger.debug "processing exclusions..."
              copy_exclude.each { |pattern| FileUtils.rm_rf(File.join(destination, pattern)) }
            end
          end
          logger.debug("start  build command")
          system(build_command)
          Dir.chdir(tmpdir) 
          if File.directory? build_target_path
              FileUtils.mv(build_target_path,destination_tmp)
              #Capistrano::CLI.ui.ask('break point')
              FileUtils.rm_rf(destination)
              FileUtils.mv(destination_tmp, destination)
          else
              FileUtils.mkdir_p(destination_tmp)
              FileUtils.cp(build_target_path,File.join(destination_tmp,"/"))
              Dir.chdir(destination_tmp)
              system("#{decompress_package_file(build_target_path).join(" ")}")
              FileUtils.rm(File.join(destination_tmp,File.basename(build_target_path)))
              Dir.chdir(tmpdir)
              FileUtils.rm_rf(destination)
              FileUtils.mv(destination_tmp, destination)
          end
          File.open(File.join(destination, "REVISION"), "w") { |f| f.puts(revision) }
          logger.trace "compressing #{destination} to #{filename} at #{tmpdir}"
          Dir.chdir(tmpdir) { system(compress(File.basename(destination), File.basename(filename)).join(" ")) }

          content = File.open(filename, "rb") { |f| f.read }
          put content, remote_filename 
          run "cd #{configuration[:releases_path]} && #{decompress(remote_filename).join(" ")} && rm #{remote_filename}"
        ensure
          FileUtils.rm filename rescue nil
          FileUtils.rm_rf destination rescue nil
          FileUtils.rm_rf destination_tmp rescue nil
        end

        def check!
          super.check do |d|
            d.local.command(source.local.command)
            d.local.command(compress(nil, nil).first)
            d.remote.command(decompress(nil).first)
          end
        end

        # Returns the location of the local copy cache, if the strategy should
        # use a local cache + copy instead of a new checkout/export every
        # time. Returns +nil+ unless :copy_cache has been set. If :copy_cache
        # is +true+, a default cache location will be returned.
        def copy_cache
          @copy_cache ||= configuration[:copy_cache] == true ?
            File.join(Dir.tmpdir, configuration[:application]) :
            configuration[:copy_cache]
        end

        private
            
          def java_home
            configuration['java_home'] || ENV['JAVA_HOME']
          end

          def build_command
            Dir.chdir("#{destination}")
            configuration[:build_command] || Capistrano::CLI.ui.ask('build command:')
          end

          def build_target_path
            File.join(destination, configuration[:build_target_path])
          end


          # Specify patterns to exclude from the copy. This is only valid
          # when using a local cache.
          def copy_exclude
            @copy_exclude ||= Array(configuration.fetch(:copy_exclude, []))
          end

          # Returns the basename of the release_path, which will be used to
          # name the local copy and archive file.
          def destination
            #configuration[:release_path]
            @destination ||= File.join(tmpdir, File.basename(configuration[:release_path]))

          end

          def destination_tmp
            #configuration[:release_path]
            @destination_tmp ||= "#{destination}_tmp"

          end

          # Returns the value of the :copy_strategy variable, defaulting to
          # :checkout if it has not been set.
          def copy_strategy
            @copy_strategy ||= configuration.fetch(:copy_strategy, :checkout)
          end

          # Should return the command(s) necessary to obtain the source code
          # locally.
          def command
            logger.debug("#{copy_strategy}")
            @command ||= case copy_strategy
            when :checkout
              source.checkout(revision, destination)
            when :export
              source.export(revision, destination)
            end
          end


          # Returns the name of the file that the source code will be
          # compressed to.
          def filename
            @filename ||= File.join(tmpdir, "#{File.basename(destination)}.#{compression_extension}")
          end

          # The directory to which the copy should be checked out
          def tmpdir
            @tmpdir ||= configuration[:copy_dir] || Dir.tmpdir
          end

          # The directory on the remote server to which the archive should be
          # copied
          def remote_dir
            @remote_dir ||= configuration[:copy_remote_dir] || "/tmp"
          end

          # The location on the remote server where the file should be
          # temporarily stored.
          def remote_filename
            @remote_filename ||= File.join(remote_dir, File.basename(filename))
          end

          # The compression method to use, defaults to :gzip.
          def compression
            @compression ||= configuration[:copy_compression] || :gzip
          end

          def package_file_compression
            @package_file_compression ||= configuration[:copy_compression] || "#{File.extname(build_target_path)}" || :gzip
          end
          # Returns the file extension used for the compression method in
          # question.
          def compression_extension
            case compression
            when :gzip, :gz   then "tar.gz"
            when :bzip2, :bz2 then "tar.bz2"
            when :zip         then "zip"
            else raise ArgumentError, "invalid compression type #{compression.inspect}"
            end
          end

          # Returns the command necessary to compress the given directory
          # into the given file. The command is returned as an array, where
          # the first element is the utility to be used to perform the compression.
          def compress(directory, file)
            case compression
            when :gzip, :gz   then ["tar", "czf", file, directory]
            when :bzip2, :bz2 then ["tar", "cjf", file, directory]
            when :zip         then ["zip", "-qr", file, directory]
            when :war         then [File.join(java_home,"/bin/jar"), "-cf", file]
            when :jar         then [File.join(java_home,"/bin/jar"), "-cf", file]
            else raise ArgumentError, "invalid compression type #{compression.inspect}"
            end
          end

          # Returns the command necessary to decompress the given file,
          # relative to the current working directory. It must also
          # preserve the directory structure in the file. The command is returned
          # as an array, where the first element is the utility to be used to
          # perform the decompression.
          def decompress(file)
            case compression
            when :gzip, :gz   then ["tar", "xzf", file]
            when :bzip2, :bz2 then ["tar", "xjf", file]
            when :zip         then ["unzip", "-q", file]
            else raise ArgumentError, "invalid compression type #{compression.inspect}"
            end
          end

          def decompress_package_file(file)
            case package_file_compression
            when :gzip, :gz   then ["tar", "xzf", file]
            when :bzip2, :bz2 then ["tar", "xjf", file]
            when :zip         then ["unzip", "-q", file]
            when ".war"         then [File.join(java_home,"/bin/jar"), "-xf", file]
            when ".jar"         then [File.join(java_home,"/bin/jar"), "-xf", file]
            else raise ArgumentError, "invalid compression type #{package_file_compression.inspect}"
            end
          end

      end

    end
  end
end
