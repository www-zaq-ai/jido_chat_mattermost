defmodule Jido.Chat.Mattermost.AttachmentEditTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.FileUpload
  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Mattermost.Test.RecordingTransport

  setup do
    Process.put({RecordingTransport, :upload_file}, {:ok, %{"file_infos" => [%{"id" => "file"}]}})

    Process.put(
      {RecordingTransport, :edit_message},
      {:ok, %{"id" => "post", "file_ids" => ["file"]}}
    )

    :ok
  end

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Adapter)
    assert Adapter.capabilities().edit_attachments == :native
  end

  test "uploads exact bytes then edits the original post without creating another" do
    assert {:ok, response} = Adapter.edit_message("room", "post", "Answer", opts())
    assert response.external_message_id == "post"
    assert response.status == :edited
    assert_received {:transport_call, :upload_file, ["room", upload, upload_opts]}
    assert upload == %{body: <<0, 255>>, filename: "file.png", content_type: "image/png"}
    assert upload_opts[:token] == "test-token"
    assert_received {:transport_call, :edit_message, ["room", "post", "Answer", edit_opts]}
    assert edit_opts[:file_ids] == ["file"]
    refute_received {:transport_call, :send_message, _}
  end

  test "upload failure or missing ID cannot edit or create a post" do
    for {result, error} <- [
          {{:error, :timeout}, :timeout},
          {{:ok, %{"file_infos" => []}}, :missing_uploaded_file_id}
        ] do
      Process.put({RecordingTransport, :upload_file}, result)
      assert {:error, ^error} = Adapter.edit_message("room", "post", "Answer", opts())
      assert_received {:transport_call, :upload_file, _}
      refute_received {:transport_call, :edit_message, _}
      refute_received {:transport_call, :send_message, _}
    end
  end

  test "edit failure never retries an upload or creates another post" do
    Process.put({RecordingTransport, :edit_message}, {:error, :timeout})
    assert {:error, :timeout} = Adapter.edit_message("room", "post", "Answer", opts())
    assert_received {:transport_call, :upload_file, _}
    assert_received {:transport_call, :edit_message, _}
    refute_received {:transport_call, _, _}
  end

  test "a successful edit that omits the uploaded file is not confirmed" do
    Process.put({RecordingTransport, :edit_message}, {:ok, %{"id" => "post", "file_ids" => []}})

    assert {:error, :unconfirmed_delivery} =
             Adapter.edit_message("room", "post", "Answer", opts())
  end

  test "text-only edits omit file IDs and multiple files fail before uploading" do
    assert {:ok, _} =
             Adapter.edit_message("room", "post", "Answer", Keyword.delete(opts(), :files))

    assert_received {:transport_call, :edit_message, ["room", "post", "Answer", edit_opts]}
    refute Keyword.has_key?(edit_opts, :file_ids)
    refute_received {:transport_call, :upload_file, _}

    [file] = opts()[:files]

    assert {:error, :multiple_attachments_unsupported} =
             Adapter.edit_message(
               "room",
               "post",
               "Answer",
               Keyword.put(opts(), :files, [file, file])
             )

    refute_received {:transport_call, _, _}
  end

  defp opts do
    [
      transport: RecordingTransport,
      token: "test-token",
      files: [
        %FileUpload{kind: :file, data: <<0, 255>>, filename: "file.png", media_type: "image/png"}
      ]
    ]
  end
end
