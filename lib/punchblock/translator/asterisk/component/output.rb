# encoding: utf-8

require 'active_support/core_ext/string/filters'
require 'punchblock/translator/asterisk/unimrcp_app'

module Punchblock
  module Translator
    class Asterisk
      module Component
        class Output < Component
          include StopByRedirect

          UnrenderableDocError  = Class.new OptionError
          UniMRCPError          = Class.new Punchblock::Error
          PlaybackError         = Class.new Punchblock::Error

          def execute
            raise OptionError, 'An SSML document is required.' unless @component_node.render_documents.first.value
            raise OptionError, 'An interrupt-on value of speech is unsupported.' if @component_node.interrupt_on == :voice

            [:start_offset, :start_paused, :repeat_interval, :repeat_times, :max_time].each do |opt|
              raise OptionError, "A #{opt} value is unsupported on Asterisk." if @component_node.send opt
            end

            early = !@call.answered?

            rendering_engine = @component_node.renderer || :asterisk

            case rendering_engine.to_sym
            when :asterisk
              setup_for_native early

              filenames.each do |doc, set|
                opts = set.join '&'
                opts << ",noanswer" if early
                @call.execute_agi_command 'EXEC Playback', opts
                if @call.channel_var('PLAYBACKSTATUS') == 'FAILED'
                  raise PlaybackError
                end
              end
            when :native_or_unimrcp
              setup_for_native early

              filenames.each do |doc, set|
                path = set.join '&'
                opts = early ? "#{path},noanswer" : path
                @call.execute_agi_command 'EXEC Playback', opts
                if @call.channel_var('PLAYBACKSTATUS') == 'FAILED'
                  fallback_doc = RubySpeech::SSML.draw do
                    children = doc.value.xpath("/ns:speak/ns:audio", ns: RubySpeech::SSML::SSML_NAMESPACE).children
                    add_child Nokogiri.jruby? ? children : children.to_xml
                  end
                  render_with_unimrcp Punchblock::Component::Output::Document.new(value: fallback_doc)
                end
              end
            when :unimrcp
              @call.send_progress if early
              send_ref
              render_with_unimrcp(*render_docs)
            when :swift
              @call.send_progress if early
              send_ref
              @call.execute_agi_command 'EXEC Swift', swift_doc
            else
              raise OptionError, "The renderer #{rendering_engine} is unsupported."
            end
            send_finish
          rescue ChannelGoneError
            call_ended
          rescue PlaybackError
            complete_with_error 'Terminated due to playback error'
          rescue UniMRCPError
            complete_with_error 'Terminated due to UniMRCP error'
          rescue RubyAMI::Error => e
            complete_with_error "Terminated due to AMI error '#{e.message}'"
          rescue UnrenderableDocError => e
            with_error 'unrenderable document error', e.message
          rescue OptionError => e
            with_error 'option error', e.message
          end

          private

          def setup_for_native(early)
            raise OptionError, "A voice value is unsupported on Asterisk." if @component_node.voice
            raise OptionError, 'Interrupt digits are not allowed with early media.' if early && @component_node.interrupt_on

            case @component_node.interrupt_on
            when :any, :dtmf
              interrupt = true
            end

            validate_audio_only

            @call.send_progress if early

            if interrupt
              output_component = current_actor
              call.register_handler :ami, :name => 'DTMF', [:[], 'End'] => 'Yes' do |event|
                output_component.stop_by_redirect finish_reason
              end
            end

            send_ref
          end

          def validate_audio_only
            filenames
          end

          def filenames
            @filenames ||= render_docs.map do |doc|
              [doc, doc.value.children.map do |node|
                case node
                when RubySpeech::SSML::Audio
                  node.src.sub('file://', '').gsub(/\.[^\.]*$/, '')
                when String
                  raise if node.include?(' ')
                  node
                else
                  raise
                end
              end.compact]
            end
          rescue
            raise UnrenderableDocError, 'The provided document could not be rendered. See http://adhearsion.com/docs/common_problems#unrenderable-document-error for details.'
          end

          def render_with_unimrcp(*docs)
            docs.each do |doc|
              UniMRCPApp.new('MRCPSynth', doc.value.to_s, mrcpsynth_options).execute @call
              raise UniMRCPError if @call.channel_var('SYNTHSTATUS') == 'ERROR'
            end
          end

          def render_docs
            @component_node.render_documents
          end

          def concatenated_render_doc
            render_docs.inject RubySpeech::SSML.draw do |doc, argument|
              doc + argument.value
            end
          end

          def mrcpsynth_options
            {}.tap do |opts|
              opts[:i] = 'any' if [:any, :dtmf].include? @component_node.interrupt_on
              opts[:v] = @component_node.voice if @component_node.voice
            end
          end

          def swift_doc
            doc = concatenated_render_doc.to_s.squish.gsub(/["\\]/) { |m| "\\#{m}" }
            doc << "|1|1" if [:any, :dtmf].include? @component_node.interrupt_on
            doc.insert 0, "#{@component_node.voice}^" if @component_node.voice
            doc
          end

          def send_finish
            send_complete_event finish_reason
          end

          def finish_reason
            Punchblock::Component::Output::Complete::Finish.new
          end
        end
      end
    end
  end
end
