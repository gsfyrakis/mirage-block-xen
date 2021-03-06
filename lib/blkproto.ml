(*
 * Copyright (c) 2011 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2012 Citrix Systems Inc
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Printf

type ('a, 'b) result = [
  | `OK of 'a
  | `Error of 'b
]
let ( >>= ) x f = match x with
  | `Error _ as y -> y
  | `OK x -> f x
let list l k =
  if not(List.mem_assoc k l)
  then `Error (Printf.sprintf "missing %s key" k)
  else `OK (List.assoc k l)
let int x = try `OK (int_of_string x) with _ -> `Error ("not an int: " ^ x)
let int32 x = try `OK (Int32.of_string x) with _ -> `Error ("not an int32: " ^ x)
let int64 x = try `OK (Int64.of_string x) with _ -> `Error ("not an int64: " ^ x)

(* Control messages via xenstore *)

module Mode = struct
  type t = ReadOnly | ReadWrite
  let to_string = function
    | ReadOnly -> "r"
    | ReadWrite -> "w"
  let of_string = function
    | "r" -> Some ReadOnly
    | "w" -> Some ReadWrite
    | _ -> None
  let to_int = function
    | ReadOnly -> 4 (* VDISK_READONLY *)
    | ReadWrite -> 0
  let of_int x = if (x land 4) = 4 then ReadOnly else ReadWrite
end

module Media = struct
  type t = CDROM | Disk
  let to_string = function
    | CDROM -> "cdrom"
    | Disk -> "disk"
  let of_string = function
    | "cdrom" -> Some CDROM
    | "disk" -> Some Disk
    | _ -> None
  let to_int = function
    | CDROM -> 1 (* VDISK_CDROM *)
    | Disk  -> 0
  let of_int x = if (x land 1) = 1 then CDROM else Disk
end

module State = struct
  type t = Initialising | InitWait | Initialised | Connected | Closing | Closed
  let table = [
    1, Initialising;
    2, InitWait;
    3, Initialised;
    4, Connected;
    5, Closing;
    6, Closed
  ]
  let table' = List.map (fun (x, y) -> y, x) table
  let to_string t = string_of_int (List.assoc t table' )
  let of_string t = try Some (List.assoc (int_of_string t) table) with _ -> None

  let of_int x =
    if List.mem_assoc x table
    then `OK (List.assoc x table)
    else `Error (Printf.sprintf "unknown device state: %d" x)

  let _state = "state"
  let keys = [ _state ]
  let of_assoc_list l =
    list l _state >>= fun x ->
    int x >>= fun x ->
    of_int x
  let to_assoc_list t = [
    _state, string_of_int (List.assoc t table')
  ]
end

module Connection = struct
  type t = {
    virtual_device: string;
    backend_path: string;
    backend_domid: int;
    frontend_path: string;
    frontend_domid: int;
    mode: Mode.t;
    media: Media.t;
    removable: bool;
  }

  let to_assoc_list t =
    let backend = [
      "frontend", t.frontend_path;
      "frontend-id", string_of_int t.frontend_domid;
      "online", "1";
      "removable", if t.removable then "1" else "0";
      "state", State.to_string State.Initialising;
      "mode", Mode.to_string t.mode;
    ] in
    let frontend = [
      "backend", t.backend_path;
      "backend-id", string_of_int t.backend_domid;
      "state", State.to_string State.Initialising;
      "virtual-device", t.virtual_device;
      "device-type", Media.to_string t.media;
    ] in
    [
      t.backend_domid, (t.backend_path, "");
      t.frontend_domid, (t.frontend_path, "");
    ]
    @ (List.map (fun (k, v) -> t.backend_domid, (Printf.sprintf "%s/%s" t.backend_path k, v)) backend)
    @ (List.map (fun (k, v) -> t.frontend_domid, (Printf.sprintf "%s/%s" t.frontend_path k, v)) frontend)
end

module Protocol = struct
  type t = X86_64 | X86_32 | Native

  let of_string = function
    | "x86_32-abi" -> `OK X86_32
    | "x86_64-abi" -> `OK X86_64
    | "native"     -> `OK Native
    | x            -> `Error ("unknown protocol: " ^ x)

  let to_string = function
    | X86_64 -> "x86_64-abi"
    | X86_32 -> "x86_32-abi"
    | Native -> "native"
end

let max_segments_per_request = 256

module FeatureIndirect = struct
  type t = {
    max_indirect_segments: int;
  }

  let _max_indirect_segments = "feature-max-indirect-segments"

  let to_assoc_list t =
    if t.max_indirect_segments = 0
    then [] (* don't advertise the feature *)
    else [ _max_indirect_segments, string_of_int t.max_indirect_segments ]

  let of_assoc_list l =
    if not(List.mem_assoc _max_indirect_segments l)
    then `OK { max_indirect_segments = 0 }
    else
      let x = List.assoc _max_indirect_segments l in
      int x >>= fun max_indirect_segments ->
      `OK { max_indirect_segments }
end

module DiskInfo = struct
  type t = {
    sector_size: int;
    sectors: int64;
    media: Media.t;
    mode: Mode.t;
  }

  let _sector_size = "sector-size"
  let _sectors = "sectors"
  let _info = "info"

  let to_assoc_list t = [
    _sector_size, string_of_int t.sector_size;
    _sectors, Int64.to_string t.sectors;
    _info, string_of_int (Media.to_int t.media lor (Mode.to_int t.mode));
  ]

  let of_assoc_list l =
    list l _sector_size >>= fun x -> int x
    >>= fun sector_size ->
    list l _sectors >>= fun x -> int64 x
    >>= fun sectors ->
    list l _info >>= fun x -> int x
    >>= fun info ->
    let media = Media.of_int info
    and mode = Mode.of_int info in
    `OK { sectors; sector_size; media; mode }
end

module RingInfo = struct
  type t = {
    ref: int32;
    event_channel: int;
    protocol: Protocol.t;
  }

  let to_string t =
    Printf.sprintf "{ ref = %ld; event_channel = %d; protocol = %s }"
    t.ref t.event_channel (Protocol.to_string t.protocol)

  let _ring_ref = "ring-ref"
  let _event_channel = "event-channel"
  let _protocol = "protocol"

  let keys = [
    _ring_ref;
    _event_channel;
    _protocol;
  ]

  let to_assoc_list t = [
    _ring_ref, Int32.to_string t.ref;
    _event_channel, string_of_int t.event_channel;
    _protocol, Protocol.to_string t.protocol
  ]

  let of_assoc_list l =
    list l _ring_ref >>= fun x -> int32 x
    >>= fun ref ->
    list l _event_channel >>= fun x -> int x
    >>= fun event_channel ->
    list l _protocol >>= fun x -> Protocol.of_string x
    >>= fun protocol ->
    `OK { ref; event_channel; protocol }
end

module Hotplug = struct
  let _hotplug_status = "hotplug-status"
  let _online = "online"
  let _params = "params"
end

(* Block requests; see include/xen/io/blkif.h *)
module Req = struct

  (* Defined in include/xen/io/blkif.h, BLKIF_REQ_* *)
  cenum op {
    Read          = 0;
    Write         = 1;
    Write_barrier = 2;
    Flush         = 3;
    Op_reserved_1 = 4; (* SLES device-specific packet *)
    Trim          = 5;
    Indirect_op   = 6;
  } as uint8_t

  let string_of_op = function
  | Read -> "Read" | Write -> "Write" | Write_barrier -> "Write_barrier"
  | Flush -> "Flush" | Op_reserved_1 -> "Op_reserved_1" | Trim -> "Trim"
  | Indirect_op -> "Indirect_op"

  exception Unknown_request_type of int

  (* Defined in include/xen/io/blkif.h BLKIF_MAX_SEGMENTS_PER_REQUEST *)
  let segments_per_request = 11

  type seg = {
    gref: int32;
    first_sector: int;
    last_sector: int;
  }

  let string_of_seg seg =
    Printf.sprintf "{gref=%ld first=%d last=%d}" seg.gref seg.first_sector seg.last_sector

  type segs =
  | Direct of seg array
  | Indirect of int32 array

  let string_of_segs = function
  | Direct segs -> Printf.sprintf "direct [ %s ]" (String.concat "; " (List.map string_of_seg (Array.to_list segs)))
  | Indirect refs -> Printf.sprintf "indirect [ %s ]" (String.concat "; " (List.map Int32.to_string (Array.to_list refs)))

  (* Defined in include/xen/io/blkif.h : blkif_request_t *)
  type t = {
    op: op option;
    handle: int;
    id: int64;
    sector: int64;
    nr_segs: int;
    segs: segs;
  }

  let string_of t =
    Printf.sprintf "{ op=%s handle=%d id=%Ld sector=%Ld segs=%s (total %d) }"
    (match t.op with Some x -> string_of_op x | None -> "None")
      t.handle t.id t.sector (string_of_segs t.segs) t.nr_segs

  (* The segment looks the same in both 32-bit and 64-bit versions *)
  cstruct segment {
    uint32_t       gref;
    uint8_t        first_sector;
    uint8_t        last_sector;
    uint16_t       _padding
  } as little_endian
  let _ = assert (sizeof_segment = 8)

  let get_segments payload nr_segs =
    Array.init nr_segs (fun i ->
      let seg = Cstruct.shift payload (i * sizeof_segment) in {
        gref = get_segment_gref seg;
        first_sector = get_segment_first_sector seg;
        last_sector = get_segment_last_sector seg;
      })

  (* The request header has a slightly different format caused by
     not using __attribute__(packed) and letting the C compiler pad *)
  module type DIRECT = sig
    val sizeof_hdr: int
    val get_hdr_op: Cstruct.t -> int
    val set_hdr_op: Cstruct.t -> int -> unit
    val get_hdr_nr_segs: Cstruct.t -> int
    val set_hdr_nr_segs: Cstruct.t -> int -> unit
    val get_hdr_handle: Cstruct.t -> int
    val set_hdr_handle: Cstruct.t -> int -> unit
    val get_hdr_id: Cstruct.t -> int64
    val set_hdr_id: Cstruct.t -> int64 -> unit
    val get_hdr_sector: Cstruct.t -> int64
    val set_hdr_sector: Cstruct.t -> int64 -> unit
  end

  (* The indirect requests have one extra field, and other fields
     have been shuffled *)
  module type INDIRECT = sig
    include DIRECT
    val get_hdr_indirect_op: Cstruct.t -> int
    val set_hdr_indirect_op: Cstruct.t -> int -> unit
  end

  module Marshalling(D: DIRECT)(I: INDIRECT) = struct
    (* total size of a request structure, in bytes *)
    let total_size = D.sizeof_hdr + (sizeof_segment * segments_per_request)

    let page_size = Io_page.round_to_page_size 1
    let segments_per_indirect_page = page_size / sizeof_segment

    let write_segments segs buffer =
      Array.iteri (fun i seg ->
        let buf = Cstruct.shift buffer (i * sizeof_segment) in
        set_segment_gref buf seg.gref;
        set_segment_first_sector buf seg.first_sector;
        set_segment_last_sector buf seg.last_sector
      ) segs

    (* Write a request to a slot in the shared ring. *)
    let write_request req (slot: Cstruct.t) = match req.segs with
      | Direct segs ->
        D.set_hdr_op slot (match req.op with None -> -1 | Some x -> op_to_int x);
        D.set_hdr_nr_segs slot req.nr_segs;
        D.set_hdr_handle slot req.handle;
        D.set_hdr_id slot req.id;
        D.set_hdr_sector slot req.sector;
        let payload = Cstruct.shift slot D.sizeof_hdr in
        write_segments segs payload;
        req.id
      | Indirect refs ->
        I.set_hdr_op slot (op_to_int Indirect_op);
        I.set_hdr_indirect_op slot (match req.op with None -> -1 | Some x -> op_to_int x);
        I.set_hdr_nr_segs slot req.nr_segs;
        I.set_hdr_handle slot req.handle;
        I.set_hdr_id slot req.id;
        I.set_hdr_sector slot req.sector;
        let payload = Cstruct.shift slot I.sizeof_hdr in
        Array.iteri (fun i gref -> Cstruct.LE.set_uint32 payload (i * 4) gref) refs;
        req.id

    let read_request slot =
      let op = int_to_op (D.get_hdr_op slot) in
      if op = Some Indirect_op then begin
        let nr_segs = I.get_hdr_nr_segs slot in
        let nr_grefs = (nr_segs + 511) / 512 in
        let payload = Cstruct.shift slot I.sizeof_hdr in
        let grefs = Array.init nr_grefs (fun i -> Cstruct.LE.get_uint32 payload (i * 4)) in {
          op = int_to_op (I.get_hdr_indirect_op slot); (* the "real" request type *)
          handle = I.get_hdr_handle slot; id = I.get_hdr_id slot;
          sector = I.get_hdr_sector slot; nr_segs;
          segs = Indirect grefs
        }
      end else begin
        let payload = Cstruct.shift slot D.sizeof_hdr in
        let segs = get_segments payload (D.get_hdr_nr_segs slot) in {
          op; handle = D.get_hdr_handle slot; id = D.get_hdr_id slot;
          sector = D.get_hdr_sector slot; nr_segs = D.get_hdr_nr_segs slot;
          segs = Direct segs
        }
      end
  end
  module Proto_64 = Marshalling(struct
    cstruct hdr {
      uint8_t        op;
      uint8_t        nr_segs;
      uint16_t       handle;
      uint32_t       _padding; (* emitted by C compiler *)
      uint64_t       id;
      uint64_t       sector
    } as little_endian
  end) (struct
    cstruct hdr {
      uint8_t        op;
      uint8_t        indirect_op;
      uint16_t       nr_segs;
      uint32_t       _padding1;
      uint64_t       id;
      uint64_t       sector;
      uint16_t       handle;
      uint16_t       _padding2;
      (* up to 8 grant references *)
    } as little_endian
  end)

  module Proto_32 = Marshalling(struct
    cstruct hdr {
      uint8_t        op;
      uint8_t        nr_segs;
      uint16_t       handle;
      (* uint32_t       _padding; -- not included *)
      uint64_t       id;
      uint64_t       sector
    } as little_endian
  end) (struct
    cstruct hdr {
      uint8_t        op;
      uint8_t        indirect_op;
      uint16_t       nr_segs;
      uint64_t       id;
      uint64_t       sector;
      uint16_t       handle;
      uint16_t       _padding1;
      (* up to 8 grant references *)
    } as little_endian
  end)
end

module Res = struct

  (* Defined in include/xen/io/blkif.h, BLKIF_RSP_* *)
  cenum rsp {
    OK            = 0;
    Error         = 0xffff;
    Not_supported = 0xfffe
  } as uint16_t

  (* Defined in include/xen/io/blkif.h, blkif_response_t *)
  type t = {
    op: Req.op option;
    st: rsp option;
  }

  (* The same structure is used in both the 32- and 64-bit protocol versions,
     modulo the extra padding at the end. *)
  cstruct response_hdr {
    uint64_t       id;
    uint8_t        op;
    uint8_t        _padding;
    uint16_t       st;
    (* 64-bit only but we don't need to care since there aren't any more fields: *)
    uint32_t       _padding2
  } as little_endian

  let write_response (id, t) slot =
    set_response_hdr_id slot id;
    set_response_hdr_op slot (match t.op with None -> -1 | Some x -> Req.op_to_int x);
    set_response_hdr_st slot (match t.st with None -> -1 | Some x -> rsp_to_int x)

  let read_response slot =
    get_response_hdr_id slot, {
      op = Req.int_to_op (get_response_hdr_op slot);
      st = int_to_rsp (get_response_hdr_st slot)
    }
end
