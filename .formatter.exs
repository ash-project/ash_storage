# Used by "mix format"
spark_locals_without_parens = [
  analyze: 1,
  analyzer: 1,
  analyzer: 2,
  attachment_resource: 1,
  attribute_type: 1,
  belongs_to_resource: 2,
  belongs_to_resource: 3,
  blob_resource: 1,
  dependent: 1,
  generate: 1,
  has_many_attached: 1,
  has_many_attached: 2,
  has_one_attached: 1,
  has_one_attached: 2,
  service: 1,
  sort: 1,
  variant: 2,
  variant: 3,
  write_attributes: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  import_deps: [:ash, :spark],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
