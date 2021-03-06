require 'awestruct/util/inflector'
require 'awestruct/util/default_inflections'

require 'awestruct/config'
require 'awestruct/site'
require 'awestruct/pipeline'
require 'awestruct/page'
require 'awestruct/page_loader'

require 'awestruct/extensions/pipeline'

require 'fileutils'
require 'set'

class OpenStruct
  def inspect
    "OpenStruct{...}"
  end
end

module Awestruct

  class Engine

    attr_reader :site
    attr_reader :pipeline

    def self.instance
      @instance
    end

    def self.instance=(engine)
      @instance = engine
    end

    def initialize(config=Awestruct::Config.new)
      Engine.instance = self
      @site = Site.new( self, config)
      @pipeline = Pipeline.new
      @site_page_loader = PageLoader.new( @site )
      @layout_page_loader = PageLoader.new( @site, :layouts )
    end

    def config
      site.config
    end

    def run(profile, base_url, default_base_url, force=false)
      adjust_load_path
      load_site_yaml(profile)
      set_base_url( base_url, default_base_url )
      load_yamls
      load_pipeline
      load_pages
      execute_pipeline
      configure_compass
      set_urls( site.pages )
      build_page_index
      generate_output
    end

    def build_page_index
      site.pages_by_relative_source_path = {}
      site.pages.each do |p|
        if ( p.relative_source_path )
          site.pages_by_relative_source_path[ p.relative_source_path ] = p
        end
      end
      site.layouts.each do |p|
        if ( p.relative_source_path )
          site.pages_by_relative_source_path[ p.relative_source_path ] = p
        end
      end
    end

    def set_base_url(base_url, default_base_url)
      if ( base_url )
        site.base_url = base_url
      end

      if ( site.base_url.nil? )
        site.base_url = default_base_url
      end

      if ( site.base_url )
        if ( site.base_url =~ /^(.*)\/$/ )
          site.base_url = $1
        end
      end

    end

    def load_site_yaml(profile)
      site_yaml = File.join( site.config.config_dir, 'site.yml' )
      if ( File.exist?( site_yaml ) )
        data = YAML.load( File.read( site_yaml ) )
        site.interpolate = true
        profile_data = {}
        data.each do |k,v|
          if ( ( k == 'profiles' ) && ( ! profile.nil? ) )
            profile_data = ( v[profile] || {} )
          else
            site.send( "#{k}=", v )
          end
        end if data
        site.profile = profile

        profile_data.each do |k,v|
          site.send( "#{k}=", v )
        end
      end
    end

    def load_yamls
      Dir[ File.join( site.config.config_dir, '*.yml' ) ].each do |yaml_path|
        load_yaml( yaml_path ) unless ( File.basename( yaml_path ) == 'site.yml' )
      end
    end

    def load_yaml(yaml_path)
      data = YAML.load( File.read( yaml_path ) )
      name = File.basename( yaml_path, '.yml' )
      site.send( "#{name}=", massage_yaml( data ) )
    end

    def massage_yaml(obj)
      result = obj
      case ( obj )
        when Hash
          result = {}
          obj.each do |k,v|
            result[k] = massage_yaml(v)
          end
          result = AStruct.new( result ).cascade_for_nils!
        when Array
          result = []
          obj.each do |v|
            result << massage_yaml(v)
          end
      end
      result
    end

    def adjust_load_path
      ext_dir = File.join( site.config.extension_dir )
      if ( $LOAD_PATH.index( ext_dir ).nil? )
        $LOAD_PATH << ext_dir
      end
    end

    def set_urls(pages)
      pages.each do |page|
        #puts "relative_source_path #{page.relative_source_path}"
        page_path = page.output_path
        if ( page_path =~ /^\// )
          page.url = page_path
        else
          page.url = "/#{page_path}"
        end
        if ( page.url =~ /^(.*\/)index.html$/ )
          page.url = $1
        end
      end
    end

    def load_pipeline
      ext_dir = File.join( site.config.extension_dir )
      pipeline_file = File.join( ext_dir, 'pipeline.rb' )
      if ( File.exists?( pipeline_file ) )
        p = eval(File.read( pipeline_file ), nil, pipeline_file, 1)
        p.extensions.each do |e|
          pipeline.extension( e )
        end
        p.helpers.each do |h|
          pipeline.helper( h )
        end
        p.transformers.each do |e|
          pipeline.transformer( e )
        end
      end
    end

    def execute_pipeline
      FileUtils.mkdir_p( site.config.output_dir )
      FileUtils.mkdir_p( site.config.tmp_dir )
      pipeline.execute( site )
    end

    def configure_compass
      Compass.configuration.project_type    = :standalone
      Compass.configuration.project_path    = site.config.dir
      Compass.configuration.sass_dir        = 'stylesheets'
      
      site.images_dir      = File.join( site.config.output_dir, 'images' )
      site.stylesheets_dir = File.join( site.config.output_dir, 'stylesheets' )
      site.javascripts_dir = File.join( site.config.output_dir, 'javascripts' )

      Compass.configuration.css_dir         = site.css_dir
      Compass.configuration.javascripts_dir = 'javascripts'
      Compass.configuration.images_dir      = 'images'
      Compass.configuration.line_comments   = include_line_comments?
    end

    def include_line_comments?
      site.key?(:compass_line_comments) ? !!site.compass_line_comments : !site.profile.eql?('production')
    end

    def load_pages
      @layout_page_loader.load_all( :post )
      @site_page_loader.load_all( :inline )
    end

    def generate_output
      FileUtils.mkdir_p( site.config.output_dir )
      @site.pages.each do |page|
        generated_path = File.join( site.config.output_dir, page.output_path )
        if ( page.stale_output?( generated_path ) )
          generate_page( page, generated_path )
        else
          generate_page( page, generated_path, false )
        end
      end
    end

    def generate_page(page, generated_path, produce_output=true)
      if ( produce_output )
        puts "Generating: #{generated_path}"
        FileUtils.mkdir_p( File.dirname( generated_path ) )

        c = page.rendered_content
        c = site.engine.pipeline.apply_transformers( site, page, c )

        File.open( generated_path, 'wb' ) do |file|
          file << c
        end
      elsif ( site.config.track_dependencies )
        if page.dependencies.load!
          puts "Cached:     #{generated_path}"
        else
          puts "Analyzing:  #{generated_path}"
          page.rendered_content
        end
      end
    end

    def generate_page_by_output_path(path)
      full_path = File.join( '', path )
      page = site.pages.find{|p| p.relative_source_path.to_s==full_path} || site.layouts.find{|p| p.relative_source_path.to_s==full_path}
      return if page.nil?

      if !page.output_path.nil?
        generate_page_internal(page)
      end

      pages = [] << page

      pages.each{|page|
        puts "--------------------"
        puts "Page: #{page.output_path} #{page.relative_source_path} #{page.__is_layout ? 'Layout':''}"
        puts "Detected change in content (#{page.dependencies.content_hash})" if page.dependencies.has_changed_content
        puts "!! Detected change in front matter. To fully reflect the change you'll need to restart Awestruct (#{page.dependencies.key_hash})" if page.dependencies.has_changed_keys
        puts "No changes detected" unless page.dependencies.has_changed_content or page.dependencies.has_changed_keys
        puts "Dependencies Matrix: (non unique source path)"
        puts "\t Outgoing dependencies:"
        puts "\t\t Content -> #{page.dependencies.dependencies.size}"
        puts "\t\t Key     -> #{page.dependencies.key_dependencies.size}"
        puts "\t Incoming dependencies:"
        puts "\t\t Content <- #{page.dependencies.dependents.size}"
        puts "\t\t Key     <- #{page.dependencies.key_dependents.size}"
        puts "--------------------"
      }

      regen_pages = Set.new
      if page.dependencies.has_changed_content or page.__is_layout
        regen_pages += page.dependencies.dependents
      end
      regen_pages = regen_pages.sort do |x, y|
        xf = "#{@site.dir}#{x.relative_source_path}"
        yf = "#{@site.dir}#{y.relative_source_path}"
        xt = 0
        yt = 0
        xt = File.mtime(xf).to_i if File.exist? xf
        yt = File.mtime(yf).to_i if File.exist? yf

        yt <=> xt
      end

      puts "Starting regeneration of content dependent pages:" if regen_pages.size > 0
      regen_pages.each{|x| puts x.output_path}

      regen_pages.each do |p|
        generate_page_internal(p)
      end
    end

    def generate_page_internal(p)
        unless ( p.output_path.nil? || p.__is_layout )
          generated_path = File.join( site.config.output_dir, p.output_path )
          generate_page( p, generated_path )
        end
    end

    ####
    ##
    ## compat with awestruct 0.2.x
    ##
    ####

    def load_page(path, options={})
      page = @site_page_loader.load_page( path )
      if ( options[:relative_path] )
        fixed_relative_path = ( options[:relative_path].nil? ? nil : File.join( '', options[:relative_path] ) )
        page.relative_path = fixed_relative_path
      end
      page
    end

    def load_site_page(relative_path)
      load_page( File.join( site.config.dir, relative_path ) )
    end

    def find_and_load_site_page(simple_path)
      path_glob = File.join( site.config.input_dir, simple_path + '.*' )
      candidates = Dir[ path_glob ]
      return nil if candidates.empty?
      throw Exception.new( "too many choices for #{simple_path}" ) if candidates.size != 1
      dir_pathname = Pathname.new( site.config.dir )
      path_name = Pathname.new( candidates[0] )
      relative_path = path_name.relative_path_from( dir_pathname ).to_s
      load_page( candidates[0] )
    end

    def create_context(page, content='')
      page.create_context( content )
    end

  end

end
