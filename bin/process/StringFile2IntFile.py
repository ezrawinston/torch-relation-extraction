__author__ = 'pat'

import re
import sys
import getopt
import pickle
from collections import defaultdict


def process_line(chars, ent_map, ep_map, line, rel_map, token_counter, double_vocab, replace_digits):
    e1_str, e2_str, rel_str, label = line.strip().split('\t')
    ep_str = e1_str + '\t' + e2_str
    tokens = list(rel_str.replace(' ', '<SPACE>')) if chars else rel_str.split(' ')

    for i, token in enumerate(tokens):
        if replace_digits and '$ARG' not in token and not re.match('\[\d\]', token):
            token = re.sub(r'[0-9]', '#', token)
        if double_vocab and 0 < i < len(tokens) - 1:
            token = token+'_'+tokens[0]
        tokens[i] = token
        token_counter[token] += 1

    # if not chars:
    rel_str = ' '.join(tokens)
    # add 1 for 1 indexing
    ent_map.setdefault(e1_str, str(len(ent_map) + 1))
    ent_map.setdefault(e2_str, str(len(ent_map) + 1))
    ep_map.setdefault(ep_str, str(len(ep_map) + 1))
    rel_map.setdefault(rel_str, str(len(rel_map) + 1))
    return e1_str, e2_str, ep_str, rel_str, tokens, label


def export_line(e1_str, e2_str, ep_str, rel_str, tokens, ent_map, ep_map, rel_map, token_map, label, out):
    # map tokens
    token_ids = [str(token_map[token]) if token in token_map else '1' for token in tokens]
    e1 = ent_map[e1_str]
    e2 = ent_map[e2_str]
    ep = ep_map[ep_str]
    rel = rel_map[rel_str]
    out.write('\t'.join([e1, e2, ep, rel, ' '.join(token_ids), label]) + '\n')


def main(argv):
    in_file = ''
    out_file = ''
    save_vocab_file = ''
    load_vocab_file = ''
    chars = False
    min_count = 0
    max_seq = sys.maxint
    double_vocab = False
    reset_tokens = False
    replace_digits = False

    help_msg = 'test.py -i <inFile> -o <outputfile> -m <throw away tokens seen less than this many times> \
-s <throw away relations longer than this> -c <use char tokens (default is use words)> -d <double vocab depending on if [A1 rel A2] or [A2 rel A1]>'
    try:
        opts, args = getopt.getopt(argv, "hi:o:dcm:s:l:v:rn", ["inFile=", "outFile=", "saveVocab=", "loadVocab=",
                "chars", "doubleVocab", "minCount=", "maxSeq=", "resetVocab", "noNumbers"])
    except getopt.GetoptError:
        print help_msg
        sys.exit(2)
    for opt, arg in opts:
        if opt == '-h':
            print help_msg
            sys.exit()
        elif opt in ("-i", "--inFile"):
            in_file = arg
        elif opt in ("-o", "--outFile"):
            out_file = arg
        elif opt in ("-m", "--minCount"):
            min_count = int(arg)
        elif opt in ("-s", "--maxSeq"):
            max_seq = int(arg)
        elif opt in ("-c", "--chars"):
            chars = True
        elif opt in ("-v", "--saveVocab"):
            save_vocab_file = arg
        elif opt in ("-l", "--loadVocab"):
            load_vocab_file = arg
        elif opt in ("-d", "--doubleVocab"):
            double_vocab = True
        elif opt in ("-r", "--resetVocab"):
            reset_tokens = True
        elif opt in ("-n", "--noNumbers"):
            replace_digits = True
    print 'Input file is "', in_file
    print 'Output file is "', out_file
    print ('Exporting char tokens' if chars else 'Exporting word tokens')

    # load memory maps from file or initialize new ones
    if load_vocab_file:
        with open(load_vocab_file, 'rb') as fp:
            [ent_map, ep_map, rel_map, token_map, token_counter] = pickle.load(fp)
        if reset_tokens:
            # this should probably be a different flag
            rel_map = {}
            token_map = {}
            token_counter = defaultdict(int)
    else:
        ent_map = {}
        ep_map = {}
        rel_map = {}
        token_map = {}
        token_counter = defaultdict(int)

    # memory map all the data and return processed lines
    print 'Processing lines and getting token counts'
    data = [process_line(chars, ent_map, ep_map, line, rel_map, token_counter, double_vocab, replace_digits)
            for line in open(in_file, 'r')]

    # prune infrequent tokens
    token_count = 1
    if reset_tokens or not load_vocab_file:
        for token, count in token_counter.iteritems():
            if count < min_count:
                token_map[token] = 1
            else:
                token_count += 1
                token_map[token] = token_count

    print 'Exporting processed lines to file'
    # export processed data
    out = open(out_file, 'w')
    [export_line(e1_str, e2_str, ep_str, rel_str, tokens, ent_map, ep_map, rel_map, token_map, label, out)
     for e1_str, e2_str, ep_str, rel_str, tokens, label in data if len(tokens) <= max_seq]
    out.close()
    print 'Num ents: ', len(ent_map), 'Num eps: ', len(ep_map), \
        'Num rels: ', len(rel_map), 'Num tokens: ', token_count

    if save_vocab_file:
        with open(save_vocab_file, 'wb') as fp:
            pickle.dump([ent_map, ep_map, rel_map, token_map, token_counter], fp)
        with open(save_vocab_file + '-tokens.txt', 'w') as fp:
            for token, index in token_map.iteritems():
                fp.write(token + '\t' + str(index) + '\n')
        with open(save_vocab_file + '-relations.txt', 'w') as fp:
            for token, index in rel_map.iteritems():
                fp.write(token + '\t' + str(index) + '\n')
        with open(save_vocab_file + '-entities.txt', 'w') as fp:
            for token, index in ent_map.iteritems():
                fp.write(token + '\t' + str(index) + '\n')
        with open(save_vocab_file + '-entpairs.txt', 'w') as fp:
            for token, index in ep_map.iteritems():
                fp.write(token + '\t' + str(index) + '\n')

if __name__ == "__main__":
    main(sys.argv[1:])