# frozen_string_literal: true

require 'test_helper'
require 'sodalite/openapi'

# Every route already carries its full declared shape as data, so the published
# document is a fold over the routes rather than a second set of annotations to
# keep in sync. The contract cannot drift from the code because it *is* the code,
# read a different way.
class OpenAPITest < Minitest::Test
  include Sodalite::TestSupport

  RUN = Berylx::Task[:present] { |lay| lay[:response].set(Sodalite.ok({ id: 1 })) }

  ROUTES = [
    Sodalite::Route[:get, '/users/:id',
                    params: { id: :integer },
                    query: { loud: :boolean?, tags: [:string] },
                    responses: { 200 => { id: :integer, kind: Zeolite.enum(:human, :bot), nick: :string? } },
                    run: RUN, name: :show_user],
    Sodalite::Route[:post, '/users',
                    body: { name: Zeolite.sized(:string, min: 1, max: 64) },
                    responses: { 201 => { id: :integer } },
                    run: RUN, name: :create_user]
  ].freeze

  def document
    Sodalite::OpenAPI.document(
      Sodalite::App.new(routes: ROUTES, handlers: Sodalite::Effects.fixed),
      title: 'users', version: '1.0'
    )
  end

  def operation(path, verb)
    document['paths'].fetch(path).fetch(verb)
  end

  # `/users/:id` is sodalite's spelling; `/users/{id}` is OpenAPI's.
  def test_a_template_is_rewritten_into_openapi_spelling
    assert_equal ['/users/{id}', '/users'], document['paths'].keys
    assert_equal 'show_user', operation('/users/{id}', 'get')['operationId']
  end

  def test_path_and_query_parameters_come_from_the_same_declaration_the_sieve_uses
    parameters = operation('/users/{id}', 'get')['parameters']

    assert_equal(%w[id loud tags], parameters.map { |parameter| parameter['name'] })
    assert_equal(%w[path query query], parameters.map { |parameter| parameter['in'] })
    assert_equal({ 'type' => 'integer' }, parameters[0]['schema'])
  end

  # A path parameter is always required; the `?` suffix only means anything for a
  # query, where a key can genuinely be absent.
  def test_optionality_is_read_from_the_declared_suffix
    parameters = operation('/users/{id}', 'get')['parameters']

    assert parameters[0]['required']
    refute parameters[1]['required']
    assert_equal({ 'type' => 'boolean', 'nullable' => true }, parameters[1]['schema'])
    assert_equal({ 'type' => 'array', 'items' => { 'type' => 'string' } }, parameters[2]['schema'])
  end

  def test_an_enum_publishes_its_closed_set
    shape = operation('/users/{id}', 'get')['responses']['200']['content'][Sodalite::JSON_TYPE]['schema']

    assert_equal({ 'type' => 'string', 'enum' => %w[human bot] }, shape['properties']['kind'])
    assert_equal({ 'type' => 'string', 'nullable' => true }, shape['properties']['nick'])
    assert_equal %w[id kind], shape['required']
  end

  # A predicate is a Ruby block and has no JSON Schema. Publishing the base type
  # alone would claim a wider contract than the service accepts, so the
  # refinement's own label goes in the description.
  def test_a_refinement_publishes_its_label_rather_than_pretending_to_be_unbounded
    body = operation('/users', 'post')['requestBody']['content'][Sodalite::JSON_TYPE]['schema']

    assert_equal({ 'type' => 'string', 'description' => 'length between 1 and 64' },
                 body['properties']['name'])
    assert operation('/users', 'post')['requestBody']['required']
  end

  # The statuses the framework itself can produce, published for the same reason
  # the successful shapes are: a client should not discover them by surprise.
  def test_the_frameworks_own_failures_are_published_too
    get = operation('/users/{id}', 'get')['responses']
    post = operation('/users', 'post')['responses']

    assert_equal %w[200 400 404 405], get.keys
    assert_equal %w[201 400 404 405 415 413], post.keys
    assert_equal 'the request does not fit the declared shape', get['400']['description']
  end

  def test_the_error_shape_published_is_the_one_actually_sent
    published = operation('/users/{id}', 'get')['responses']['400']['content'][Sodalite::JSON_TYPE]['schema']
    triple = app(ROUTES.first).call(env(:get, '/users/abc'))

    assert_predicate Sodalite::Errors::SCHEMA.parse(triple[2].join), :ok?
    assert_equal %w[error violations], published['properties'].keys
  end

  def test_the_document_declares_its_own_version_and_info
    assert_equal '3.1.0', document['openapi']
    assert_equal({ 'title' => 'users', 'version' => '1.0' }, document['info'])
  end
end
