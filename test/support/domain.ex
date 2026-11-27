defmodule AshStorage.Test.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshStorage.Test.Post
    resource AshStorage.Test.Comment
    resource AshStorage.Test.Blob
    resource AshStorage.Test.Attachment
    resource AshStorage.Test.PolymorphicAttachment
    resource AshStorage.Test.MultiAttachment
    resource AshStorage.Test.ConfigurablePost
    resource AshStorage.Test.AnalyzablePost
    resource AshStorage.Test.VariantPost
    resource AshStorage.Test.IntegerPost
    resource AshStorage.Test.IntegerAttachment
    resource AshStorage.Test.ExtraAttrsPost
    resource AshStorage.Test.ChecksumVerifyingPost
    resource AshStorage.Test.ActorRequiredPost
    resource AshStorage.Test.NoHeadPost
    resource AshStorage.Test.MultipartEtagPost
    resource AshStorage.Test.NestedPathPost
    resource AshStorage.Test.PathAttachment
    resource AshStorage.Test.PathPost
    resource AshStorage.Test.Tenant
    resource AshStorage.Test.KeyRulesPost
    resource AshStorage.Test.MatrixPost
    resource AshStorage.Test.Matrix.Context.Blob
    resource AshStorage.Test.Matrix.Context.Attachment
    resource AshStorage.Test.Matrix.Context.Post
    resource AshStorage.Test.Matrix.Attribute.Blob
    resource AshStorage.Test.Matrix.Attribute.Attachment
    resource AshStorage.Test.Matrix.Attribute.Post
    resource AshStorage.Test.Matrix.Actor.Blob
    resource AshStorage.Test.Matrix.Actor.Attachment
    resource AshStorage.Test.Matrix.Actor.Post
    resource AshStorage.Test.Matrix.Deny.Blob
    resource AshStorage.Test.Matrix.Deny.Attachment
    resource AshStorage.Test.Matrix.Deny.Post
  end
end
