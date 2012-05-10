# TinyGem: A tiny gem build tool

Version 1.0.0

Home: https://github.com/gabrielg/tinygem

`tinygem` is a tool to build a RubyGem from a single file. `tinygem` itself is
built using `tinygem`.

## Dependencies

`tinygem` has no library dependencies. It requires Ruby 1.9.

## Install

`gem install tinygem`

## Examples

Here's an example file to create a gem from:

    =begin
    author: Gabriel Gironda
    email: gabriel@gironda.org
    version: 1.0.0
    summary: A tinygem example
    description: Example gem created using tinygem
    homepage: http://www.example.com/
    executable: puts(ARGV.inspect)
    ---

    # Example gem

    ## TODO - Write README

    =end

    class ExampleGem
      # Do something
    end

Save this in `example.rb`, then run `tinygem example.rb`.

## TODO

* Add support for specifying runtime dependencies
* Write better docs