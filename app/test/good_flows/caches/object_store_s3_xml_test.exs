defmodule GoodFlows.Caches.ObjectStoreS3XMLTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Caches.ObjectStore.S3XML

  @ns ~s( xmlns="http://s3.amazonaws.com/doc/2006-03-01/")

  test "InitiateMultipartUploadResult gives the upload id" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <InitiateMultipartUploadResult#{@ns}><Bucket>b</Bucket><Key>k</Key><UploadId>a+b/c=</UploadId></InitiateMultipartUploadResult>
    """

    assert S3XML.upload_id(xml) == {:ok, "a+b/c="}
    assert S3XML.upload_id("<InitiateMultipartUploadResult/>") == :error
    assert S3XML.upload_id("<Error><Code>AccessDenied</Code></Error>") == :error
  end

  test "a ListPartsResult page, last and truncated, with both ETag quotings" do
    last = """
    <ListPartsResult#{@ns}><Bucket>b</Bucket><IsTruncated>false</IsTruncated>
      <Part><PartNumber>1</PartNumber><LastModified>2026-11-19T00:00:00.000Z</LastModified><ETag>&quot;AB12&quot;</ETag><Size>16777216</Size></Part>
      <Part><PartNumber>2</PartNumber><ETag>&#34;cd34&#34;</ETag><Size>6445568</Size></Part>
    </ListPartsResult>
    """

    assert S3XML.list_parts(last) ==
             {:ok,
              [
                %{number: 1, etag: "ab12", size: 16_777_216},
                %{number: 2, etag: "cd34", size: 6_445_568}
              ], nil}

    truncated = """
    <ListPartsResult#{@ns}><IsTruncated>true</IsTruncated><NextPartNumberMarker>1000</NextPartNumberMarker>
      <Part><PartNumber>1000</PartNumber><ETag>"ef"</ETag><Size>5</Size></Part>
    </ListPartsResult>
    """

    assert S3XML.list_parts(truncated) == {:ok, [%{number: 1000, etag: "ef", size: 5}], 1000}

    assert S3XML.list_parts("<ListPartsResult><IsTruncated>false</IsTruncated></ListPartsResult>") ==
             {:ok, [], nil}

    assert S3XML.list_parts("<ListPartsResult><IsTruncated>true</IsTruncated></ListPartsResult>") ==
             :error

    assert S3XML.list_parts(
             "<ListPartsResult><Part><PartNumber>x</PartNumber></Part></ListPartsResult>"
           ) ==
             :error
  end

  test "CompleteMultipartUploadResult and errors in its body" do
    ok =
      "<CompleteMultipartUploadResult#{@ns}><ETag>&quot;x-2&quot;</ETag></CompleteMultipartUploadResult>"

    assert S3XML.complete_result(ok) == :ok

    assert S3XML.complete_result("<Error><Code>InvalidPart</Code><Message>m</Message></Error>") ==
             {:error, {:rejected, "InvalidPart"}}

    assert S3XML.complete_result("<Error><Code>InternalError</Code></Error>") ==
             {:error, {:store_error, "InternalError"}}

    assert S3XML.complete_result("not xml") == :error
  end

  test "an Error body gives its code" do
    assert S3XML.error_code("<Error><Code>NoSuchUpload</Code><UploadId>x</UploadId></Error>") ==
             "NoSuchUpload"

    assert S3XML.error_code("") == nil
    assert S3XML.error_code("<Other/>") == nil
  end

  test "entity declarations are refused" do
    xml = """
    <?xml version="1.0"?>
    <!DOCTYPE r [<!ENTITY x "boom">]>
    <Error><Code>&x;</Code></Error>
    """

    assert S3XML.parse(xml) == :error
    assert S3XML.error_code(xml) == nil
  end
end
