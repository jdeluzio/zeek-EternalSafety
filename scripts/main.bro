@load smb_consts

module EternalSafety;
    
# Set to True to enable some debug prints
const DEBUG = T;

export {
    redef enum Notice::Type += {
        EternalBlue,     # => possible EternalBlue exploit
        EternalSynergy,  # => possible EternalSynergy/EternalRomance exploit
        DoublePulsar,    # => possible DoublePulsar backdoor
        ViolationPidMid, # => server introduced new PID or MID, a protocol 
                         #    violation and possible indication of 
                         #    compromise/backdoor covert channel
        ViolationCmd,    # => SMBv1 client sent unused/unimplemented command
        ViolationTx2Cmd, # => SMBv1 client sent unused TRANSACTION2 subcommand
        # TODO: implement this once Zeek has full SMBv1 support
        # ViolationNtTxCmd,# => SMBv1 client sent unused NT_TRANSACT subcommand
    };

    # SMB transactions are uniquely identified by <pid, mid, tid, uid>
    type SMBTransID: record {
        pid: count; # Process ID
        mid: count; # Multiplex ID
        tid: count; # Tree ID
        uid: count; # User ID
    };

    type SMBStreamID: record {
        pid: count; # Process ID
        mid: count; # Multiplex ID
    };

    # Table to track SMBv1 transactions per connection
    # use a set here because for our TXn invariants we don't care about
    # command sequence
    type SMBTransTable: table[SMBTransID] of set[count];

    # Table to track streams per connection
    # use a vector because we do care about command sequence for
    # some of our stream-related invariants
    type SMBStreamTable: table[SMBStreamID] of vector of count;

    # Set of notice types
    type NoticeSet: set[Notice::Type];
}

redef record connection += {
    # track SMBv1 transactions within the connection
    es_smb_trans: SMBTransTable &default=SMBTransTable();
    es_current_smb_trans: SMBTransID &optional;

    # track SMB connection streams
    es_smb_streams: SMBStreamTable &default=SMBStreamTable();
    es_current_smb_stream: SMBStreamID &optional;

    # track whether we have warned about each type of exploit, so we only warn
    # once per connection
    es_notices_issued: NoticeSet &default=NoticeSet();
};

event bro_init()
    {
    }

event connection_established(c: connection)
    {
    }

# Issues a new notice if such a notice hasn't already been issued for the
# current connection
function notice(c: connection, n: Notice::Info)
    {
    # Only issue the notice if it hasn't already been issued for this conn
    if (n$note !in c$es_notices_issued)
        {
        add c$es_notices_issued[n$note];
        if (DEBUG)
            {
            # add Wireshark-readable timestamp in debug mode
            # and print to stdout in addition to NOTICE()
            n$msg = fmt("t=%s: %s", network_time(), n$msg);
            print n$msg;
            }
        NOTICE(n);
        }
    }

# Track a new SMB command as part of the current SMB session
function seen_smb_command(c: connection, command: count)
    {
    # track transactions
    if (c$es_current_smb_trans !in c$es_smb_trans)
        c$es_smb_trans[c$es_current_smb_trans] = set(command);
    else 
        add c$es_smb_trans[c$es_current_smb_trans][command];

    # track the stream
    if (c$es_current_smb_stream !in c$es_smb_streams)
        c$es_smb_streams[c$es_current_smb_stream] = vector(command);
    else 
        c$es_smb_streams[c$es_current_smb_stream] += command;
    }

# Triggers if SMB client sends unimplemented/unused primary SMB command
function invariant_unused_smb_cmd(c: connection, hdr: SMB1::Header, 
                                  is_orig: bool)
    {
    # if this is a response from the server, just ignore it
    if (!is_orig)
        return;

    # else raise notice if this is a client->srv message with an unused command
    else if (hdr$command in SMB_COM_UNUSED)
            notice(c,
                   [$note=ViolationCmd,
                    $msg=fmt("SMBv1 proto violation, possibly malicious " +
                             "activity: %s:%s sent unused/unimplemented " +
                             "command 0x%x to %s:%s",
                             c$id$orig_h, c$id$orig_p,
                             hdr$command,
                             c$id$resp_h, c$id$resp_p),
                    $conn=c]);
    }

# Server is not allowed to introduce a new MID into the stream.
# Only client can do this. DoublePulsar violates this invariant.
function invariant_new_pid_mid_from_server(c: connection, hdr: SMB1::Header,
                                           is_orig: bool)
    {
    # Client is allowed to vary these fields
    if (is_orig)
        return;

    # message is from server and is not preceeded by any corresponding message
    # from client, and this is the first message with this (pid, mid) combo
    if (|c$es_smb_streams[c$es_current_smb_stream]| == 1)
        {
        # These MID values in a Trans2 resp are usually used by DoublePulsar
        if (hdr$command == SMB_COM_TRANSACTION2 &&
              hdr$mid >= 81 && hdr$mid <= 83)
            notice(c,
                   [$note=DoublePulsar,
                    $msg=fmt("Possible DoublePulsar backdoor detected on %s:%s",
                             c$id$resp_h, c$id$resp_p),
                    $conn=c]);
        # Any other invalid value => raise a more general notice
        else
            {
            # 0xFFFF is a valid value only for SMB_COM_LOCKING_ANDX
            # See: https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-cifs/9ab1f759-689d-481a-b160-b8f0eb09f5fb
            if (hdr$command == SMB_COM_LOCKING_ANDX && hdr$mid == 0xFFFF)
                return;

            # All other cases are now a violation...
            notice(c, 
                   [$note=ViolationPidMid,
                    $msg=fmt("Possible compromised SMBv1 server %s:%s " +
                             "(srv sent new PID/MID - protocol violation)", 
                             c$id$resp_h, c$id$resp_p),
                    $conn=c]);
            }
        }
    }

# Note: this gets executed before the other smb1_* events
# NOTE: if is_orig == T, then the message is a request. Else, it is a resp.
event smb1_message(c: connection, hdr: SMB1::Header, is_orig: bool)
    {
    local current_trans: SMBTransID = [
        $pid = hdr$pid,
        $mid = hdr$mid,
        $tid = hdr$tid,
        $uid = hdr$uid
    ];

    local current_stream: SMBStreamID = [
        $pid = hdr$pid,
        $mid = hdr$mid
    ];

    c$es_current_smb_trans = current_trans;
    c$es_current_smb_stream = current_stream;

    seen_smb_command(c, hdr$command);

    # check that invariants hold
    # these functions raise notices as appropriate for violations
    invariant_new_pid_mid_from_server(c, hdr, is_orig);
    invariant_unused_smb_cmd(c, hdr, is_orig);
    }

# Produces a notice if an unused/unimplemented TRANS2 sub-command is seen
function invariant_unused_trans2_subcmd(c: connection, trans2_sub_cmd: count)
    {
    if (trans2_sub_cmd in TRANS2_UNUSED)
        notice(c,
               [$note=ViolationCmd,
                $msg=fmt("SMBv1 proto violation, possibly malicious " +
                         "activity: %s:%s sent unused/unimplemented " +
                         "TRANSACTION2 subcommand 0x%04x to %s:%s",
                         c$id$orig_h, c$id$orig_p,
                         trans2_sub_cmd,
                         c$id$resp_h, c$id$resp_p),
                $conn=c]);
    }

# Trans2 Request (0x32) MS-2.2.4.46.1
event smb1_transaction2_request(c: connection, hdr: SMB1::Header, 
                                args: SMB1::Trans2_Args, sub_cmd: count)
    {
    invariant_unused_trans2_subcmd(c, sub_cmd);
    }

# Trans2 Secondary Request (0x33) MS:2.2.4.47.1
# Check here for interleaving NT_TRANSACT and TRANS2 commands, which are a
# protocol violation and probably indicate an exploit attempt
event smb1_transaction2_secondary_request(c: connection, hdr: SMB1::Header,
                                          args: SMB1::Trans2_Sec_Args, 
                                          parameters: string, data: string)
    {
    # SMB protocol violation used by EternalBlue:
    # NT_TRANSACT and TRANSACTION2 transaction types must NOT be interleaved.
    if (SMB_COM_NT_TRANSACT in c$es_smb_trans[c$es_current_smb_trans])
            notice(c, 
                   [$note=EternalBlue,
                    $msg=fmt("SMBv1 proto violation, possible " +
                             "EternalBlue or other buffer exploit: " +
                             "%s:%s tried to interleave NT_TRANSACT " +
                             "and TRANS2 commands in request to %s:%s",
                             c$id$orig_h, c$id$orig_p,
                             c$id$resp_h, c$id$resp_p),
                    $conn=c]);
    }

event smb1_write_andx_request(c: connection, hdr: SMB1::Header, 
                              file_id: count, offset: count, data_len: count)
    {
    # Invariant: WRITE_ANDX must NOT be interleaved with SMB_COM_TRANSACTION
    if (|SMB_ALL_TRANS_CMDS & c$es_smb_trans[c$es_current_smb_trans]| > 0)
        notice(c, 
               [$note=EternalSynergy,
                $msg=fmt("Possible EternalSynergy exploit: SMBv1 WRITE_ANDX " +
                         "interleaved with other transaction type in request " +
                         "from %s:%s to %s:%s",
                         c$id$orig_h, c$id$orig_p,
                         c$id$resp_h, c$id$resp_p),
                $conn=c]);
    }

event bro_done()
    {
    }
