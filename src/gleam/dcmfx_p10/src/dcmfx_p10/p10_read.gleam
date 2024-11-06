//// Converts incoming chunks of binary DICOM P10 data into DICOM P10 parts.
////
//// This conversion is done in a streaming fashion, where chunks of incoming
//// raw binary data are added to a read context, and DICOM P10 parts are then
//// progressively made available as their data comes in. See the `P10Part` type
//// for details on the different parts that are emitted.
////
//// If DICOM P10 data already exists fully in memory it can be added to a new
//// read context as one complete and final chunk, and then have its DICOM parts
//// read out, i.e. there is no requirement to use a read context in a streaming
//// fashion, and in either scenario a series of DICOM P10 parts will be made
//// available by the read context.
////
//// Additional configuration for controlling memory usage when reading DICOM
//// P10 data is available via `P10ReadConfig`.

import dcmfx_character_set
import dcmfx_core/data_element_tag.{type DataElementTag, DataElementTag}
import dcmfx_core/data_element_value
import dcmfx_core/data_error
import dcmfx_core/data_set.{type DataSet}
import dcmfx_core/data_set_path.{type DataSetPath}
import dcmfx_core/registry
import dcmfx_core/transfer_syntax.{type TransferSyntax, BigEndian, LittleEndian}
import dcmfx_core/value_representation.{type ValueRepresentation}
import dcmfx_p10/internal/byte_stream.{type ByteStream}
import dcmfx_p10/internal/data_element_header.{
  type DataElementHeader, DataElementHeader,
}
import dcmfx_p10/internal/p10_location.{type P10Location}
import dcmfx_p10/p10_error.{type P10Error}
import dcmfx_p10/p10_part.{type P10Part}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result

/// Configuration used when reading DICOM P10 data. The following config is
/// available:
///
/// ### `max_part_size: Int`
///
/// The maximum size in bytes of a DICOM P10 part emitted by a read context.
/// This can be used to control memory usage during a streaming read, and must
/// be a multiple of 8.
///
/// The maximum part size is relevant to two specific parts:
///
/// 1. `FileMetaInformation`, where it sets the maximum size in bytes of the
///    File Meta Information, as specified by the File Meta Information Group
///    Length value. If this size is exceeded an error will occur when reading
///    the DICOM P10 data.
///
/// 2. `DataElementValueBytes`, where it sets the maximum size in bytes of its
///    `data` (with the exception of non-UTF-8 string data, see
///    `with_max_string_size` for further details). Data element values with a
///    length exceeding this size will be split across multiple
///    `DataElementValueBytes` parts.
///
/// By default there is no limit on the maximum part size, that is, each data
/// element will have its value bytes emitted in exactly one
/// `DataElementValueBytes` part.
///
/// ### `max_string_size: Int`
///
/// The maximum size in bytes of non-UTF-8 strings that can be read by a read
/// context. This can be used to control memory usage during a streaming read.
///
/// The maximum string size is relevant to data elements containing string
/// values that are not encoded in UTF-8. Such string data is converted to UTF-8
/// by the read context, which requires that the whole string value be read into
/// memory.
///
/// Specifically:
///
/// 1. The maximum string size sets a hard upper limit on the size of a
///    non-UTF-8 string value that can be read. Data element values containing
///    non-UTF-8 string data larger that the maximum string size will result in
///    an error. Because of this, the maximum size should not be set too low.
///
/// 2. The maximum string size can be set larger than the maximum part size to
///    allow more leniency in regard to the size of string data that can be
///    parsed, while keeping part sizes smaller for other common cases such as
///    image data.
///
/// By default there is no limit on the maximum string size.
///
/// ### `max_sequence_depth: Int`
///
/// The maximum sequence depth that can be read by a read context. This can be
/// used to control memory usage during a streaming read, as well as to reject
/// malformed or malicious DICOM P10 data.
///
/// By default the maximum sequence depth is set to ten thousand, i.e. no
/// meaningful maximum is enforced.
///
pub type P10ReadConfig {
  P10ReadConfig(
    max_part_size: Int,
    max_string_size: Int,
    max_sequence_depth: Int,
  )
}

/// Returns the default read config.
///
pub fn default_config() -> P10ReadConfig {
  P10ReadConfig(
    max_part_size: 0xFFFFFFFE,
    max_string_size: 0xFFFFFFFE,
    max_sequence_depth: 10_000,
  )
}

/// A read context holds the current state of an in-progress DICOM P10 read. Raw
/// DICOM P10 data is added to a read context with `write_bytes`, and DICOM P10
/// parts are then read out with `read_parts`.
///
/// An updated read context is returned whenever data is added or parts are read
/// out, and the updated read context must be used for subsequent calls.
///
pub opaque type P10ReadContext {
  P10ReadContext(
    config: P10ReadConfig,
    stream: ByteStream,
    next_action: NextAction,
    transfer_syntax: TransferSyntax,
    path: DataSetPath,
    location: P10Location,
    sequence_depth: Int,
  )
}

/// The next action specifies what will be attempted to be read next from a read
/// context by `read_parts`.
///
type NextAction {
  ReadFilePreambleAndDICMPrefix
  ReadFileMetaInformation(starts_at: Int)
  ReadDataElementHeader
  ReadDataElementValueBytes(
    tag: DataElementTag,
    vr: ValueRepresentation,
    length: Int,
    bytes_remaining: Int,
    emit_parts: Bool,
  )
  ReadPixelDataItem(vr: ValueRepresentation)
}

/// Creates a new read context for reading DICOM P10 data.
///
pub fn new_read_context() -> P10ReadContext {
  P10ReadContext(
    config: default_config(),
    stream: byte_stream.new(0xFFFFFFFE),
    next_action: ReadFilePreambleAndDICMPrefix,
    transfer_syntax: transfer_syntax.implicit_vr_little_endian,
    path: data_set_path.new(),
    location: p10_location.new(),
    sequence_depth: 0,
  )
}

/// Updates the config for a read context.
///
pub fn with_config(
  context: P10ReadContext,
  config: P10ReadConfig,
) -> P10ReadContext {
  // Round max part size to a multiple of 8
  let max_part_size = { config.max_part_size / 8 } * 8
  let max_string_size = int.max(config.max_string_size, max_part_size)
  let max_sequence_depth = int.max(0, config.max_sequence_depth)

  let max_read_size = int.max(config.max_string_size, config.max_part_size)

  let config =
    P10ReadConfig(
      max_part_size: max_part_size,
      max_string_size: max_string_size,
      max_sequence_depth: max_sequence_depth,
    )

  P10ReadContext(
    ..context,
    stream: byte_stream.new(max_read_size),
    config: config,
  )
}

/// Sets the transfer syntax to use when reading DICOM P10 data that doesn't
/// specify a transfer syntax in its File Meta Information, or doesn't have any
/// File Meta Information.
///
/// The default is 'Implicit VR Little Endian'.
///
/// The fallback transfer syntax should be set prior to reading any DICOM P10
/// parts from the read context.
///
pub fn set_fallback_transfer_syntax(
  context: P10ReadContext,
  transfer_syntax: TransferSyntax,
) -> P10ReadContext {
  P10ReadContext(..context, transfer_syntax:)
}

/// Returns the transfer syntax for a P10 read context. This defaults to
/// 'Implicit VR Little Endian' and is updated when a transfer syntax is read
/// from the File Meta Information.
///
/// The default transfer syntax can be set using
/// `set_fallback_transfer_syntax()`.
///
pub fn transfer_syntax(context: P10ReadContext) -> TransferSyntax {
  context.transfer_syntax
}

/// Writes raw DICOM P10 bytes to a read context that will be parsed into
/// DICOM P10 parts by subsequent calls to `read_parts()`. If `done` is true
/// this indicates the end of the incoming DICOM P10 data to be parsed, after
/// which any further calls to this function will error.
///
pub fn write_bytes(
  context: P10ReadContext,
  bytes: BitArray,
  done: Bool,
) -> Result(P10ReadContext, P10Error) {
  case byte_stream.write(context.stream, bytes, done) {
    Ok(stream) -> Ok(P10ReadContext(..context, stream: stream))

    Error(e) ->
      Error(map_byte_stream_error(
        context,
        e,
        "Writing data to DICOM P10 read context",
      ))
  }
}

/// Reads the next DICOM P10 parts from a read context. On success, zero or more
/// parts are returned and the function can be called again to read further
/// parts.
///
/// On error, a value of `DataRequired` means the read context does not have
/// enough data to return the next part, i.e. further calls to `write_bytes`
/// are required before the next part is able to be read.
///
pub fn read_parts(
  context: P10ReadContext,
) -> Result(#(List(P10Part), P10ReadContext), P10Error) {
  case context.next_action {
    ReadFilePreambleAndDICMPrefix ->
      read_file_preamble_and_dicm_prefix_part(context)

    ReadFileMetaInformation(starts_at) -> {
      use #(fmi_data_set, new_context) <- result.map(
        read_file_meta_information_part(context, starts_at),
      )

      #([p10_part.FileMetaInformation(fmi_data_set)], new_context)
    }

    ReadDataElementHeader -> {
      // If there is a delimiter part for a defined-length sequence or item
      // that needs to be emitted then return that as the next part
      let delimiter_part = next_delimiter_part(context)
      use <- bool.guard(delimiter_part.0 != [], Ok(delimiter_part))

      // Detect the end of the DICOM data
      case byte_stream.is_fully_consumed(context.stream) {
        True -> {
          // Return the parts required to end any active sequences and items.
          //
          // This means there is no check that all items and sequences have been
          // ended as should occur in well-formed P10 data, i.e. P10 data can be
          // truncated on a data element boundary and no error will be thrown.
          //
          // If there's a desire to error on truncated data then add a check
          // that `list.rest(context.location) == Ok([])`.

          let parts = p10_location.pending_delimiter_parts(context.location)

          Ok(#(parts, context))
        }

        // There is more data so start reading the next data element
        False -> read_data_element_header_part(context)
      }
    }

    ReadDataElementValueBytes(
      tag,
      vr,
      value_length,
      bytes_remaining,
      emit_parts,
    ) ->
      read_data_element_value_bytes_part(
        context,
        tag,
        vr,
        value_length,
        bytes_remaining,
        emit_parts,
      )

    ReadPixelDataItem(vr) -> read_pixel_data_item_part(context, vr)
  }
}

/// Checks whether there is a delimiter part that needs to be emitted, and if so
/// then returns it.
///
fn next_delimiter_part(
  context: P10ReadContext,
) -> #(List(P10Part), P10ReadContext) {
  let bytes_read = byte_stream.bytes_read(context.stream)

  case p10_location.next_delimiter_part(context.location, bytes_read) {
    Ok(#(part, new_location)) -> {
      // Decrement the sequence depth if this is a sequence delimiter
      let new_sequence_depth = case part {
        p10_part.SequenceDelimiter -> context.sequence_depth - 1
        _ -> context.sequence_depth
      }

      // Update current path
      let new_path = case part {
        p10_part.SequenceDelimiter | p10_part.SequenceItemDelimiter ->
          data_set_path.pop(context.path)
        _ -> context.path
      }

      let new_context =
        P10ReadContext(
          ..context,
          path: new_path,
          location: new_location,
          sequence_depth: new_sequence_depth,
        )

      #([part], new_context)
    }

    Error(Nil) -> #([], context)
  }
}

/// Reads the 128-byte File Preamble and the 4-byte `DICM` prefix following it.
/// If the `DICM` bytes aren't present at the expected offset then it is
/// assumed that the File Preamble is not present in the input, and a File
/// Preamble containing all zero bytes is returned.
///
fn read_file_preamble_and_dicm_prefix_part(
  context: P10ReadContext,
) -> Result(#(List(P10Part), P10ReadContext), P10Error) {
  let r = case byte_stream.peek(context.stream, 132) {
    Ok(data) ->
      case data {
        <<preamble:bytes-size(128), "DICM">> -> {
          let assert Ok(new_stream) = byte_stream.read(context.stream, 132)

          Ok(#(preamble, new_stream.1))
        }

        // There is no DICM prefix, so return an empty preamble
        _ -> Ok(#(<<0:size(8)-unit(128)>>, context.stream))
      }

    // If the end of the data is encountered when trying to read the first 132
    // bytes then there is no File Preamble so return empty preamble bytes
    Error(byte_stream.DataEnd) -> Ok(#(<<0:size(8)-unit(128)>>, context.stream))

    Error(e) -> Error(map_byte_stream_error(context, e, "Reading file header"))
  }
  use #(preamble, new_stream) <- result.try(r)

  let part = p10_part.FilePreambleAndDICMPrefix(preamble)

  let new_context =
    P10ReadContext(
      ..context,
      stream: new_stream,
      next_action: ReadFileMetaInformation(byte_stream.bytes_read(new_stream)),
    )

  Ok(#([part], new_context))
}

/// Reads the File Meta Information into a data set and returns the relevant
/// P10 part once complete. If there is a *'(0002,0000) File Meta Information
/// Group Length'* data element present then it is used to specify where the
/// File Meta Information ends. If it is not present then data elements are
/// read until one with a group other than 0x0002 is encountered.
///
fn read_file_meta_information_part(
  context: P10ReadContext,
  starts_at: Int,
) -> Result(#(DataSet, P10ReadContext), P10Error) {
  use #(fmi_data_set, new_context) <- result.try(
    read_file_meta_information_data_set(
      context,
      starts_at,
      None,
      data_set.new(),
    ),
  )

  // If the transfer syntax is deflated then all data following the File
  // Meta Information needs to passed through zlib inflate before reading.
  let new_stream = case new_context.transfer_syntax.is_deflated {
    True ->
      case byte_stream.start_zlib_inflate(new_context.stream) {
        Ok(stream) -> Ok(stream)
        Error(_) ->
          Error(p10_error.DataInvalid(
            "Starting zlib decompression for deflated transfer syntax",
            "Zlib data is invalid",
            None,
            Some(byte_stream.bytes_read(context.stream)),
          ))
      }
    False -> Ok(new_context.stream)
  }
  use new_stream <- result.map(new_stream)

  // Set the final transfer syntax in the File Meta Information part
  let fmi_data_set = case
    new_context.transfer_syntax == transfer_syntax.implicit_vr_little_endian
  {
    True -> fmi_data_set
    False -> {
      let assert Ok(fmi_data_set) =
        data_set.insert_string_value(
          fmi_data_set,
          registry.transfer_syntax_uid,
          [new_context.transfer_syntax.uid],
        )

      fmi_data_set
    }
  }

  let new_context =
    P10ReadContext(
      ..new_context,
      stream: new_stream,
      next_action: ReadDataElementHeader,
    )

  #(fmi_data_set, new_context)
}

fn read_file_meta_information_data_set(
  context: P10ReadContext,
  starts_at: Int,
  ends_at: Option(Int),
  fmi_data_set: DataSet,
) -> Result(#(DataSet, P10ReadContext), P10Error) {
  // Check if the end of the File Meta Information has been reached
  let is_ended = case ends_at {
    Some(ends_at) -> byte_stream.bytes_read(context.stream) >= ends_at
    None -> False
  }
  use <- bool.guard(is_ended, Ok(#(fmi_data_set, context)))

  // Peek the next 8 bytes that contain the group, element, VR, and two bytes
  // that contain the value length if the VR has a 16-bit length field
  let data =
    byte_stream.peek(context.stream, 8)
    |> result.map_error(fn(e) {
      map_byte_stream_error(context, e, "Reading File Meta Information")
    })
  use data <- result.try(data)

  let assert <<
    group:16-unsigned-little,
    element:16-unsigned-little,
    vr_byte_0,
    vr_byte_1,
    _:bytes,
  >> = data
  let tag = DataElementTag(group:, element:)

  // If the FMI length isn't known and the group isn't 0x0002 then assume
  // that this is the end of the File Meta Information
  use <- bool.guard(
    tag.group != 0x0002 && ends_at == None,
    Ok(#(fmi_data_set, context)),
  )

  // If a data element is encountered in the File Meta Information that doesn't
  // have a group of 0x0002 then the File Meta Information is invalid
  use <- bool.lazy_guard(tag.group != 0x0002 && ends_at != None, fn() {
    Error(p10_error.DataInvalid(
      when: "Reading File Meta Information",
      details: "Data element in File Meta Information does not have the group "
        <> "0x0002",
      path: Some(data_set_path.new_with_data_element(tag)),
      offset: Some(byte_stream.bytes_read(context.stream)),
    ))
  })

  // Get the VR for the data element
  let vr =
    <<vr_byte_0, vr_byte_1>>
    |> value_representation.from_bytes()
    |> result.map_error(fn(_) {
      p10_error.DataInvalid(
        when: "Reading File Meta Information",
        details: "Data element has invalid VR",
        path: Some(data_set_path.new_with_data_element(tag)),
        offset: Some(byte_stream.bytes_read(context.stream)),
      )
    })
  use vr <- result.try(vr)

  // Check the VR isn't a sequence as these aren't allowed in the File
  // Meta Information
  use <- bool.lazy_guard(vr == value_representation.Sequence, fn() {
    Error(p10_error.DataInvalid(
      when: "Reading File Meta Information",
      details: "Data element in File Meta Information is a sequence",
      path: Some(data_set_path.new_with_data_element(tag)),
      offset: Some(byte_stream.bytes_read(context.stream)),
    ))
  })

  // Read the value length based on whether the VR has a 16-bit or 32-bit
  // length stored
  let value_result = case data_element_header.value_length_size(vr) {
    // 16-bit lengths are read out of the 8 bytes already read
    data_element_header.ValueLengthU16 -> {
      let assert <<_:48, length:16-unsigned-little>> = data
      Ok(#(8, length))
    }

    // 32-bit lengths require another 4 bytes to be read
    data_element_header.ValueLengthU32 ->
      case byte_stream.peek(context.stream, 12) {
        Ok(data) -> {
          let assert <<_:64, length:32-unsigned-little>> = data
          Ok(#(12, length))
        }
        Error(e) ->
          Error(map_byte_stream_error(
            context,
            e,
            "Reading File Meta Information",
          ))
      }
  }
  use #(value_offset, value_length) <- result.try(value_result)

  let data_element_size = value_offset + value_length

  // Check that the File Meta Information remains under the max part size
  use <- bool.lazy_guard(
    data_set.total_byte_size(fmi_data_set) + data_element_size
      > context.config.max_part_size,
    fn() {
      Error(p10_error.MaximumExceeded(
        details: "File Meta Information exceeds the max part size of "
          <> int.to_string(context.config.max_part_size)
          <> " bytes",
        path: data_set_path.new_with_data_element(tag),
        offset: byte_stream.bytes_read(context.stream),
      ))
    },
  )

  // Read the value bytes for the data element
  let read_result =
    context.stream
    |> byte_stream.read(data_element_size)
    |> result.map_error(fn(e) {
      map_byte_stream_error(
        context,
        e,
        "Reading File Meta Information data element value",
      )
    })
  use #(data, new_stream) <- result.try(read_result)

  // Construct new data element value
  let assert Ok(value_bytes) = bit_array.slice(data, value_offset, value_length)
  let value = data_element_value.new_binary_unchecked(vr, value_bytes)

  // If this data element specifies the File Meta Information group's length
  // then use it to calculate its end offset
  let ends_at = case tag == registry.file_meta_information_group_length.tag {
    True ->
      case ends_at, data_set.is_empty(fmi_data_set) {
        None, True ->
          case data_element_value.get_int(value) {
            Ok(i) -> Ok(Some(starts_at + 12 + i))
            Error(e) ->
              Error(p10_error.DataInvalid(
                when: "Reading File Meta Information",
                details: "Group length is invalid: " <> data_error.to_string(e),
                path: Some(data_set_path.new_with_data_element(tag)),
                offset: Some(byte_stream.bytes_read(context.stream)),
              ))
          }
        _, _ -> Ok(ends_at)
      }
    False -> Ok(ends_at)
  }
  use ends_at <- result.try(ends_at)

  // If this data element specifies the transfer syntax to use then set it in
  // the read context
  let transfer_syntax = case tag == registry.transfer_syntax_uid.tag {
    True ->
      case data_element_value.get_string(value) {
        Ok(uid) ->
          uid
          |> transfer_syntax.from_uid
          |> result.map_error(fn(_) {
            p10_error.TransferSyntaxNotSupported(transfer_syntax_uid: uid)
          })

        Error(e) ->
          case data_error.is_tag_not_present(e) {
            True -> Ok(context.transfer_syntax)
            False ->
              Error(p10_error.DataInvalid(
                when: "Reading File Meta Information",
                details: data_error.to_string(e),
                path: data_error.path(e),
                offset: Some(byte_stream.bytes_read(context.stream)),
              ))
          }
      }

    False -> Ok(context.transfer_syntax)
  }
  use transfer_syntax <- result.try(transfer_syntax)

  let fmi_data_set = case
    tag == registry.file_meta_information_group_length.tag
  {
    True -> fmi_data_set
    False -> data_set.insert(fmi_data_set, tag, value)
  }

  let new_context =
    P10ReadContext(..context, stream: new_stream, transfer_syntax:)

  read_file_meta_information_data_set(
    new_context,
    starts_at,
    ends_at,
    fmi_data_set,
  )
}

fn read_data_element_header_part(
  context: P10ReadContext,
) -> Result(#(List(P10Part), P10ReadContext), P10Error) {
  // Read a data element header if bytes for one are available
  use #(header, new_stream) <- result.try(read_data_element_header(context))

  // If the VR is UN (Unknown) then attempt to infer it
  let vr = case header.vr {
    Some(value_representation.Unknown) ->
      Some(p10_location.infer_vr_for_tag(context.location, header.tag))
    vr -> vr
  }

  case header.tag, vr, header.length {
    // If this is the start of a new sequence then add it to the location
    tag, Some(value_representation.Sequence), _
    | tag, Some(value_representation.Unknown), 0xFFFFFFFF
    -> {
      let part = p10_part.SequenceStart(tag, value_representation.Sequence)

      let ends_at = case header.length == 0xFFFFFFFF {
        True -> None
        False -> Some(byte_stream.bytes_read(new_stream) + header.length)
      }

      // When the original VR was unknown and the length is undefined, as per
      // DICOM Correction Proposal CP-246 the 'Implicit VR Little Endian'
      // transfer syntax must be used to read the sequence's data.
      // Ref: https://dicom.nema.org/dicom/cp/cp246_01.pdf.
      let is_implicit_vr = header.vr == Some(value_representation.Unknown)

      let new_location =
        p10_location.add_sequence(
          context.location,
          tag,
          is_implicit_vr,
          ends_at,
        )
        |> result.map_error(fn(details) {
          p10_error.DataInvalid(
            "Reading data element header",
            details,
            Some(context.path),
            Some(byte_stream.bytes_read(context.stream)),
          )
        })
      use new_location <- result.try(new_location)

      // Check that the maximum sequence depth hasn't been reached
      let sequence_depth_check = case
        context.sequence_depth < context.config.max_sequence_depth
      {
        True -> Ok(Nil)
        False ->
          Error(p10_error.MaximumExceeded(
            "Maximum allowed sequence depth reached",
            context.path,
            byte_stream.bytes_read(context.stream),
          ))
      }
      use _ <- result.try(sequence_depth_check)

      // Add sequence to the path
      let assert Ok(new_path) =
        data_set_path.add_data_element(context.path, tag)

      let new_context =
        P10ReadContext(
          ..context,
          stream: new_stream,
          path: new_path,
          location: new_location,
          sequence_depth: context.sequence_depth + 1,
        )

      Ok(#([part], new_context))
    }

    // If this is the start of a new sequence item then add it to the location
    tag, None, length if tag == registry.item.tag -> {
      let part = p10_part.SequenceItemStart

      let ends_at = case header.length == 0xFFFFFFFF {
        True -> None
        False -> Some(byte_stream.bytes_read(new_stream) + length)
      }

      let new_location =
        p10_location.add_item(context.location, ends_at, header.length)
        |> result.map_error(fn(details) {
          p10_error.DataInvalid(
            "Reading data element header",
            details,
            Some(context.path),
            Some(byte_stream.bytes_read(context.stream)),
          )
        })
      use new_location <- result.try(new_location)

      // Add item to the path
      let item_count =
        p10_location.sequence_item_count(new_location) |> result.unwrap(1)
      let assert Ok(new_path) =
        data_set_path.add_sequence_item(context.path, item_count - 1)

      let new_context =
        P10ReadContext(
          ..context,
          stream: new_stream,
          path: new_path,
          location: new_location,
        )

      Ok(#([part], new_context))
    }

    // If this is an encapsulated pixel data sequence then add it to the current
    // location and update the next action to read its items
    tag, Some(value_representation.OtherByteString), 0xFFFFFFFF
    | tag, Some(value_representation.OtherWordString), 0xFFFFFFFF
      if tag == registry.pixel_data.tag
    -> {
      let assert Some(vr) = vr
      let part = p10_part.SequenceStart(tag, vr)

      let new_location =
        p10_location.add_sequence(context.location, tag, False, None)
        |> result.map_error(fn(details) {
          p10_error.DataInvalid(
            "Reading data element header",
            details,
            Some(context.path),
            Some(byte_stream.bytes_read(context.stream)),
          )
        })
      use new_location <- result.try(new_location)

      let new_context =
        P10ReadContext(
          ..context,
          stream: new_stream,
          next_action: ReadPixelDataItem(vr),
          location: new_location,
        )

      Ok(#([part], new_context))
    }

    // If this is a sequence delimitation item then remove the current sequence
    // from the current location
    tag, None, 0 if tag == registry.sequence_delimitation_item.tag -> {
      let #(parts, new_path, new_location, new_sequence_depth) = case
        p10_location.end_sequence(context.location)
      {
        Ok(new_location) -> {
          let new_path = data_set_path.pop(context.path)
          let new_sequence_depth = context.sequence_depth - 1

          #(
            [p10_part.SequenceDelimiter],
            new_path,
            new_location,
            new_sequence_depth,
          )
        }

        // If a sequence delimiter occurs outside of a sequence then no error is
        // returned and P10 parsing continues. This is done because rogue
        // sequence delimiters have been observed in some DICOM P10 data, and
        // not propagating an error right here doesn't do any harm and allows
        // such data to be read.
        Error(_) -> #(
          [],
          context.path,
          context.location,
          context.sequence_depth,
        )
      }

      let new_context =
        P10ReadContext(
          ..context,
          stream: new_stream,
          path: new_path,
          location: new_location,
          sequence_depth: new_sequence_depth,
        )

      Ok(#(parts, new_context))
    }

    // If this is an item delimitation item then remove the latest item from the
    // location
    tag, None, 0 if tag == registry.item_delimitation_item.tag -> {
      let part = p10_part.SequenceItemDelimiter

      let new_location =
        p10_location.end_item(context.location)
        |> result.map_error(fn(details) {
          p10_error.DataInvalid(
            "Reading data element header",
            details,
            Some(context.path),
            Some(byte_stream.bytes_read(context.stream)),
          )
        })
      use new_location <- result.try(new_location)

      let new_path = data_set_path.pop(context.path)

      let new_context =
        P10ReadContext(
          ..context,
          stream: new_stream,
          path: new_path,
          location: new_location,
        )

      Ok(#([part], new_context))
    }

    // For all other cases this is a standard data element that needs to have
    // its value bytes read
    tag, Some(vr), _ -> {
      let materialized_value_required =
        is_materialized_value_required(context, header.tag, vr)

      // If this data element needs to be fully materialized then check it
      // doesn't exceed the max string size
      let max_size_check_result = case
        materialized_value_required
        && header.length > context.config.max_string_size
      {
        True ->
          Error(p10_error.MaximumExceeded(
            "Value for '"
              <> registry.tag_with_name(header.tag, None)
              <> "' with VR "
              <> value_representation.to_string(vr)
              <> " and length "
              <> int.to_string(header.length)
              <> " bytes exceeds the maximum allowed string size of "
              <> int.to_string(header.length)
              <> " bytes",
            context.path,
            byte_stream.bytes_read(context.stream),
          ))
        False -> Ok(Nil)
      }
      use _ <- result.try(max_size_check_result)

      // If the whole value is being materialized then the DataElementHeader
      // part is only emitted once all the data is available. This is necessary
      // because in the case of string values that are being converted to UTF-8
      // the length of the final string value following UTF-8 conversion is not
      // yet known.
      let parts = case materialized_value_required {
        True -> []
        False -> [p10_part.DataElementHeader(header.tag, vr, header.length)]
      }

      // Swallow the '(FFFC,FFFC) Data Set Trailing Padding' data element. No
      // parts for it are emitted. Ref: PS3.10 7.2.
      // Also swallow group length tags that have an element of 0x0000.
      // Ref: PS3.5 7.2.
      let emit_parts =
        header.tag != registry.data_set_trailing_padding.tag
        && header.tag.element != 0x0000

      let parts = case emit_parts {
        True -> parts
        False -> []
      }

      let next_action =
        ReadDataElementValueBytes(
          header.tag,
          vr,
          header.length,
          header.length,
          emit_parts,
        )

      // Add data element to the path
      let assert Ok(new_path) =
        data_set_path.add_data_element(context.path, tag)

      let new_context =
        P10ReadContext(
          ..context,
          stream: new_stream,
          next_action: next_action,
          path: new_path,
        )

      Ok(#(parts, new_context))
    }

    _, None, _ ->
      Error(p10_error.DataInvalid(
        "Reading data element header",
        "Invalid data element '" <> data_element_header.to_string(header) <> "'",
        Some(context.path),
        Some(byte_stream.bytes_read(context.stream)),
      ))
  }
}

/// Reads a data element header. Depending on the transfer syntax and the
/// specific VR (for explicit VR transfer syntaxes), this reads either 8 or 12
/// bytes in total.
///
fn read_data_element_header(
  context: P10ReadContext,
) -> Result(#(DataElementHeader, ByteStream), P10Error) {
  let transfer_syntax = active_transfer_syntax(context)

  // Peek the 4 bytes containing the tag
  let tag = case byte_stream.peek(context.stream, 4) {
    Ok(data) -> {
      let #(group, element) = case transfer_syntax.endianness {
        transfer_syntax.LittleEndian -> {
          let assert <<group:16-unsigned-little, element:16-unsigned-little>> =
            data
          #(group, element)
        }
        transfer_syntax.BigEndian -> {
          let assert <<group:16-unsigned-big, element:16-unsigned-big>> = data
          #(group, element)
        }
      }

      Ok(DataElementTag(group, element))
    }

    Error(e) ->
      Error(map_byte_stream_error(context, e, "Reading data element header"))
  }
  use tag <- result.try(tag)

  // The item and delimitation tags always use implicit VRs
  let vr_serialization = case
    tag == registry.item.tag
    || tag == registry.item_delimitation_item.tag
    || tag == registry.sequence_delimitation_item.tag
  {
    True -> transfer_syntax.VrImplicit
    False -> transfer_syntax.vr_serialization
  }

  case vr_serialization {
    transfer_syntax.VrExplicit -> read_explicit_vr_and_length(context, tag)
    transfer_syntax.VrImplicit -> read_implicit_vr_and_length(context, tag)
  }
}

/// Returns the transfer syntax that should be used to decode the current data.
/// This will always be the transfer syntax specified in the File Meta
/// Information, except in the case of 'Implicit VR Little Endian' being forced
/// by an explicit VR of `UN` (Unknown) that has an undefined length.
///
/// Ref: DICOM Correction Proposal CP-246.
///
fn active_transfer_syntax(context: P10ReadContext) -> TransferSyntax {
  case p10_location.is_implicit_vr_forced(context.location) {
    True -> transfer_syntax.implicit_vr_little_endian
    False -> context.transfer_syntax
  }
}

/// Reads the (implicit) VR and value length following a data element tag when
/// the transfer syntax is 'Implicit VR Little Endian'.
///
fn read_implicit_vr_and_length(
  context: P10ReadContext,
  tag: DataElementTag,
) -> Result(#(DataElementHeader, ByteStream), P10Error) {
  case byte_stream.read(context.stream, 8) {
    Ok(#(data, new_stream)) -> {
      let value_length = case active_transfer_syntax(context).endianness {
        transfer_syntax.LittleEndian -> {
          let assert <<_:bytes-4, value_length:32-little-unsigned>> = data
          value_length
        }
        transfer_syntax.BigEndian -> {
          let assert <<_:bytes-4, value_length:32-big-unsigned>> = data
          value_length
        }
      }

      // Return the VR as `None` for those tags that don't support one. All
      // other tags are returned as UN (Unknown) for now and will have their VR
      // inferred in due course.
      let vr = case
        tag == registry.item.tag
        || tag == registry.item_delimitation_item.tag
        || tag == registry.sequence_delimitation_item.tag
      {
        True -> None
        False -> Some(value_representation.Unknown)
      }

      let header = DataElementHeader(tag, vr, value_length)

      Ok(#(header, new_stream))
    }

    Error(e) ->
      Error(map_byte_stream_error(context, e, "Reading data element header"))
  }
}

/// Reads the explicit VR and value length following a data element tag when
/// the transfer syntax is not 'Implicit VR Little Endian'.
///
fn read_explicit_vr_and_length(
  context: P10ReadContext,
  tag: DataElementTag,
) -> Result(#(DataElementHeader, ByteStream), P10Error) {
  // Peek and validate the explicit VR
  let vr = case byte_stream.peek(context.stream, 6) {
    Ok(data) -> {
      let assert <<_:bytes-4, vr_bytes:bytes-2>> = data

      case value_representation.from_bytes(vr_bytes) {
        Ok(vr) -> Ok(vr)

        _ ->
          // If the explicit VR is two spaces then treat it as implicit VR and
          // attempt to infer the correct VR for the data element.
          //
          // Doing this is not part of the DICOM P10 spec, but such data has
          // been observed in the wild.
          case vr_bytes {
            <<0x20, 0x20>> ->
              Ok(p10_location.infer_vr_for_tag(context.location, tag))

            _ ->
              Error(p10_error.DataInvalid(
                "Reading data element VR",
                "Unrecognized VR "
                  <> bit_array.inspect(vr_bytes)
                  <> " for tag '"
                  <> registry.tag_with_name(tag, None)
                  <> "'",
                Some(context.path),
                Some(byte_stream.bytes_read(context.stream)),
              ))
          }
      }
    }

    Error(e) ->
      Error(map_byte_stream_error(
        context,
        e,
        "Reading explicit VR data element header",
      ))
  }
  use vr <- result.try(vr)

  // If reading the VR succeeded continue by reading the value length that
  // follows it. The total size of the header in bytes varies by VR.
  let header_size = case data_element_header.value_length_size(vr) {
    data_element_header.ValueLengthU16 -> 8
    data_element_header.ValueLengthU32 -> 12
  }

  // Read the full header, including the tag, VR, and value length
  case byte_stream.read(context.stream, header_size) {
    Ok(#(data, new_stream)) -> {
      // Parse value length
      let length = case header_size {
        12 ->
          case active_transfer_syntax(context).endianness {
            transfer_syntax.LittleEndian -> {
              let assert <<_:bytes-8, length:32-little-unsigned>> = data
              length
            }
            transfer_syntax.BigEndian -> {
              let assert <<_:bytes-8, length:32-big-unsigned>> = data
              length
            }
          }
        _ ->
          case active_transfer_syntax(context).endianness {
            transfer_syntax.LittleEndian -> {
              let assert <<_:bytes-6, length:16-little-unsigned>> = data
              length
            }
            transfer_syntax.BigEndian -> {
              let assert <<_:bytes-6, length:16-big-unsigned>> = data
              length
            }
          }
      }

      let header = DataElementHeader(tag, Some(vr), length)
      Ok(#(header, new_stream))
    }

    Error(e) ->
      Error(map_byte_stream_error(
        context,
        e,
        "Reading explicit VR data element header",
      ))
  }
}

fn read_data_element_value_bytes_part(
  context: P10ReadContext,
  tag: DataElementTag,
  vr: ValueRepresentation,
  value_length: Int,
  bytes_remaining: Int,
  emit_parts: Bool,
) -> Result(#(List(P10Part), P10ReadContext), P10Error) {
  let materialized_value_required =
    is_materialized_value_required(context, tag, vr)

  // If this data element value is being fully materialized then it needs to be
  // read as a whole, so use its full length as the number of bytes to read.
  // Otherwise, read up to the max part size.
  let bytes_to_read = case materialized_value_required {
    True -> value_length
    False -> int.min(bytes_remaining, context.config.max_part_size)
  }

  case byte_stream.read(context.stream, bytes_to_read) {
    Ok(#(data, new_stream)) -> {
      // Data element values are always returned in little endian, so if this is
      // a big endian transfer syntax then convert to little endian
      let data = case active_transfer_syntax(context).endianness {
        LittleEndian -> data
        BigEndian -> value_representation.swap_endianness(vr, data)
      }

      let bytes_remaining = bytes_remaining - bytes_to_read

      let materialized_value_result = case materialized_value_required {
        True -> process_materialized_data_element(context, tag, vr, data)
        False -> Ok(#(data, context.location))
      }
      use #(data, new_location) <- result.try(materialized_value_result)

      // If this is a materialized value then the data element header for it
      // needs to be emitted, along with its final value bytes
      let parts = case materialized_value_required {
        True -> [
          p10_part.DataElementHeader(tag, vr, bit_array.byte_size(data)),
          p10_part.DataElementValueBytes(vr, data, bytes_remaining),
        ]
        False -> [p10_part.DataElementValueBytes(vr, data, bytes_remaining)]
      }

      let next_action = case bytes_remaining {
        // This data element is complete, so the next action is either to read
        // the next pixel data item if currently reading encapsulated pixel
        // data, or to read the header for the next data element
        0 ->
          case tag == registry.pixel_data.tag && value_length == 0xFFFFFFFF {
            True -> ReadPixelDataItem(vr)
            False -> ReadDataElementHeader
          }

        // Continue reading value bytes for this data element
        _ ->
          ReadDataElementValueBytes(
            tag,
            vr,
            value_length,
            bytes_remaining,
            emit_parts,
          )
      }

      let new_path = case bytes_remaining {
        0 -> data_set_path.pop(context.path)
        _ -> context.path
      }

      let new_context =
        P10ReadContext(
          ..context,
          stream: new_stream,
          next_action: next_action,
          path: new_path,
          location: new_location,
        )

      let parts = case emit_parts {
        True -> parts
        False -> []
      }

      Ok(#(parts, new_context))
    }

    Error(e) -> {
      let when =
        "Reading "
        <> int.to_string(bytes_to_read)
        <> " data element value bytes, VR: "
        <> value_representation.to_string(vr)

      Error(map_byte_stream_error(context, e, when))
    }
  }
}

fn is_materialized_value_required(
  context: P10ReadContext,
  tag: DataElementTag,
  vr: ValueRepresentation,
) -> Bool {
  // If this is a clarifying data element then its data needs to be materialized
  use <- bool.guard(p10_location.is_clarifying_data_element(tag), True)

  // If the value is a string, and it isn't UTF-8 data that can be passed
  // straight through, then materialize it so that it can be converted to UTF-8.
  //
  // In theory, strings that are defined to use ISO-646/US-ASCII don't need to
  // be sanitized as they're already valid UTF-8, but DICOM P10 data has been
  // observed that contains invalid ISO-646 data, hence they are sanitized by
  // replacing invalid characters with a question mark.
  value_representation.is_string(vr)
  && !{
    value_representation.is_encoded_string(vr)
    && p10_location.is_specific_character_set_utf8_compatible(context.location)
  }
}

fn process_materialized_data_element(
  context: P10ReadContext,
  tag: DataElementTag,
  vr: ValueRepresentation,
  value_bytes: BitArray,
) -> Result(#(BitArray, P10Location), P10Error) {
  // Decode string values using the relevant character set
  let value_bytes = case value_representation.is_string(vr) {
    True ->
      case value_representation.is_encoded_string(vr) {
        True ->
          p10_location.decode_string_bytes(context.location, vr, value_bytes)
        False -> dcmfx_character_set.sanitize_default_charset_bytes(value_bytes)
      }

    False -> value_bytes
  }

  // Update the P10 location with the materialized value, this will only do
  // something when this is a clarifying data element
  p10_location.add_clarifying_data_element(
    context.location,
    tag,
    vr,
    value_bytes,
  )
}

fn read_pixel_data_item_part(
  context: P10ReadContext,
  vr: ValueRepresentation,
) -> Result(#(List(P10Part), P10ReadContext), P10Error) {
  case read_data_element_header(context) {
    Ok(#(header, new_stream)) ->
      case header {
        // Pixel data items should have no VR and aren't allowed to have
        // undefined length
        DataElementHeader(tag, None, length)
          if tag == registry.item.tag && length != 0xFFFFFFFF
        -> {
          let part = p10_part.PixelDataItem(length)

          let next_action =
            ReadDataElementValueBytes(
              registry.pixel_data.tag,
              vr,
              0xFFFFFFFF,
              length,
              True,
            )

          let new_context =
            P10ReadContext(
              ..context,
              stream: new_stream,
              next_action: next_action,
            )

          Ok(#([part], new_context))
        }

        DataElementHeader(tag, None, 0)
          if tag == registry.sequence_delimitation_item.tag
        -> {
          let part = p10_part.SequenceDelimiter

          let new_location =
            p10_location.end_sequence(context.location)
            |> result.map_error(fn(details) {
              p10_error.DataInvalid(
                "Reading encapsulated pixel data item",
                details,
                Some(context.path),
                Some(byte_stream.bytes_read(context.stream)),
              )
            })
          use new_location <- result.try(new_location)

          let next_action = ReadDataElementHeader

          let new_context =
            P10ReadContext(
              ..context,
              stream: new_stream,
              next_action: next_action,
              location: new_location,
            )

          Ok(#([part], new_context))
        }

        _ ->
          Error(p10_error.DataInvalid(
            "Reading encapsulated pixel data item",
            "Invalid data element '"
              <> data_element_header.to_string(header)
              <> "'",
            Some(context.path),
            Some(byte_stream.bytes_read(context.stream)),
          ))
      }

    Error(e) -> Error(e)
  }
}

/// Takes an error from the byte stream and maps it through to a P10 error for
/// the passed context.
///
fn map_byte_stream_error(
  context: P10ReadContext,
  error: byte_stream.ByteStreamError,
  when: String,
) -> P10Error {
  let offset = byte_stream.bytes_read(context.stream)

  case error {
    byte_stream.DataRequired -> p10_error.DataRequired(when)

    byte_stream.DataEnd ->
      p10_error.DataEndedUnexpectedly(when, context.path, offset)

    byte_stream.ZlibDataError ->
      p10_error.DataInvalid(
        when,
        "Zlib data is invalid",
        Some(context.path),
        Some(offset),
      )

    byte_stream.WriteAfterCompletion -> p10_error.WriteAfterCompletion

    byte_stream.ReadOversized ->
      p10_error.OtherError("Maximum read size exceeded", "Internal logic error")
  }
}
