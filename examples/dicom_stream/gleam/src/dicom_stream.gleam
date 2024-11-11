import dcmfx_p10.{read_parts_from_stream, write_parts_to_stream}
import dcmfx_p10/p10_error.{type P10Error}
import dcmfx_p10/p10_read.{type P10ReadContext}
import dcmfx_p10/p10_write.{type P10WriteContext}
import file_streams/file_stream.{type FileStream}

const input_file = "../../example.dcm"

const output_file = "output.dcm"

pub fn main() -> Result(Nil, P10Error) {
  let assert Ok(input_stream) = file_stream.open_read(input_file)
  let assert Ok(output_stream) = file_stream.open_write(output_file)

  let read_context = p10_read.new_read_context()
  let write_context = p10_write.new_write_context()

  stream_parts(input_stream, output_stream, read_context, write_context)
}

fn stream_parts(
  input_stream: FileStream,
  output_stream: FileStream,
  read_context: P10ReadContext,
  write_context: P10WriteContext,
) -> Result(Nil, P10Error) {
  case read_parts_from_stream(input_stream, read_context) {
    Ok(#(parts, read_context)) ->
      case write_parts_to_stream(parts, output_stream, write_context) {
        Ok(#(ended, write_context)) ->
          case ended {
            True -> Ok(Nil)
            False ->
              stream_parts(
                input_stream,
                output_stream,
                read_context,
                write_context,
              )
          }

        Error(e) -> Error(e)
      }

    Error(e) -> Error(e)
  }
}
