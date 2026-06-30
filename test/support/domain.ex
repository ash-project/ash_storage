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
  end
end
